// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert' show BASE64;
import 'dart:math' as math;

import 'package:file/file.dart';
import 'package:json_rpc_2/error_code.dart' as rpc_error_code;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:meta/meta.dart' show required;
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'base/common.dart';
import 'base/file_system.dart';
import 'globals.dart';
import 'vmservice_record_replay.dart';

/// A function that opens a two-way communication channel to the specified [uri].
typedef StreamChannel<String> _OpenChannel(Uri uri);

_OpenChannel _openChannel = _defaultOpenChannel;

/// A function that reacts to the invocation of the 'reloadSources' service.
///
/// The VM Service Protocol allows clients to register custom services that
/// can be invoked by other clients through the service protocol itself.
///
/// Clients like Observatory use external 'reloadSources' services,
/// when available, instead of the VM internal one. This allows these clients to
/// invoke Flutter HotReload when connected to a Flutter Application started in
/// hot mode.
///
/// See: https://github.com/dart-lang/sdk/issues/30023
typedef Future<Null> ReloadSources(
  String isolateId, {
  bool force,
  bool pause,
});

const String _kRecordingType = 'vmservice';

StreamChannel<String> _defaultOpenChannel(Uri uri) =>
    new IOWebSocketChannel.connect(uri.toString()).cast();

/// The default VM service request timeout.
const Duration kDefaultRequestTimeout = const Duration(seconds: 30);

/// Used for RPC requests that may take a long time.
const Duration kLongRequestTimeout = const Duration(minutes: 1);

/// Used for RPC requests that should never take a long time.
const Duration kShortRequestTimeout = const Duration(seconds: 5);

/// A connection to the Dart VM Service.
class VMService {
  VMService._(
    this._peer,
    this.httpAddress,
    this.wsAddress,
    this._requestTimeout,
    ReloadSources reloadSources,
  ) {
    _vm = new VM._empty(this);
    _peer.listen().catchError(_connectionError.completeError);

    _peer.registerMethod('streamNotify', (rpc.Parameters event) {
      _handleStreamNotify(event.asMap);
    });

    if (reloadSources != null) {
      _peer.registerMethod('reloadSources', (rpc.Parameters params) async {
        final String isolateId = params['isolateId'].value;
        final bool force = params.asMap['force'] ?? false;
        final bool pause = params.asMap['pause'] ?? false;

        if (isolateId is! String || isolateId.isEmpty)
          throw new rpc.RpcException.invalidParams('Invalid \'isolateId\': $isolateId');
        if (force is! bool)
          throw new rpc.RpcException.invalidParams('Invalid \'force\': $force');
        if (pause is! bool)
          throw new rpc.RpcException.invalidParams('Invalid \'pause\': $pause');

        try {
          await reloadSources(isolateId, force: force, pause: pause);
          return <String, String>{'type': 'Success'};
        } on rpc.RpcException {
          rethrow;
        } catch (e, st) {
          throw new rpc.RpcException(rpc_error_code.SERVER_ERROR,
              'Error during Sources Reload: $e\n$st');
        }
      });

      // If the Flutter Engine doesn't support service registration this will
      // have no effect
      _peer.sendNotification('_registerService', <String, String>{
        'service': 'reloadSources',
        'alias': 'Flutter Tools'
      });
    }
  }

  /// Enables recording of VMService JSON-rpc activity to the specified base
  /// recording [location].
  ///
  /// Activity will be recorded in a subdirectory of [location] named
  /// `"vmservice"`. It is permissible for [location] to represent an existing
  /// non-empty directory as long as there is no collision with the
  /// `"vmservice"` subdirectory.
  static void enableRecordingConnection(String location) {
    final Directory dir = getRecordingSink(location, _kRecordingType);
    _openChannel = (Uri uri) {
      final StreamChannel<String> delegate = _defaultOpenChannel(uri);
      return new RecordingVMServiceChannel(delegate, dir);
    };
  }

  /// Enables VMService JSON-rpc replay mode.
  ///
  /// [location] must represent a directory to which VMService JSON-rpc
  /// activity has been recorded (i.e. the result of having been previously
  /// passed to [enableRecordingConnection]), or a [ToolExit] will be thrown.
  static void enableReplayConnection(String location) {
    final Directory dir = getReplaySource(location, _kRecordingType);
    _openChannel = (Uri uri) => new ReplayVMServiceChannel(dir);
  }

  /// Connect to a Dart VM Service at [httpUri].
  ///
  /// Requests made via the returned [VMService] time out after [requestTimeout]
  /// amount of time, which is [kDefaultRequestTimeout] by default.
  ///
  /// If the [reloadSources] parameter is not null, the 'reloadSources' service
  /// will be registered. The VM Service Protocol allows clients to register
  /// custom services that can be invoked by other clients through the service
  /// protocol itself.
  ///
  /// See: https://github.com/dart-lang/sdk/commit/df8bf384eb815cf38450cb50a0f4b62230fba217
  static Future<VMService> connect(
    Uri httpUri, {
    Duration requestTimeout: kDefaultRequestTimeout,
    ReloadSources reloadSources,
  }) async {
    final Uri wsUri = httpUri.replace(scheme: 'ws', path: fs.path.join(httpUri.path, 'ws'));
    final StreamChannel<String> channel = _openChannel(wsUri);
    final rpc.Peer peer = new rpc.Peer.withoutJson(jsonDocument.bind(channel));
    final VMService service = new VMService._(peer, httpUri, wsUri, requestTimeout, reloadSources);
    // This call is to ensure we are able to establish a connection instead of
    // keeping on trucking and failing farther down the process.
    await service._sendRequest('getVersion', const <String, dynamic>{});
    return service;
  }

  final Uri httpAddress;
  final Uri wsAddress;
  final rpc.Peer _peer;
  final Duration _requestTimeout;
  final Completer<Map<String, dynamic>> _connectionError = new Completer<Map<String, dynamic>>();

  VM _vm;
  /// The singleton [VM] object. Owns [Isolate] and [FlutterView] objects.
  VM get vm => _vm;

  final Map<String, StreamController<ServiceEvent>> _eventControllers =
      <String, StreamController<ServiceEvent>>{};

  final Set<String> _listeningFor = new Set<String>();

  /// Whether our connection to the VM service has been closed;
  bool get isClosed => _peer.isClosed;
  Future<Null> get done => _peer.done;

  // Events
  Stream<ServiceEvent> get onDebugEvent => onEvent('Debug');
  Stream<ServiceEvent> get onExtensionEvent => onEvent('Extension');
  // IsolateStart, IsolateRunnable, IsolateExit, IsolateUpdate, ServiceExtensionAdded
  Stream<ServiceEvent> get onIsolateEvent => onEvent('Isolate');
  Stream<ServiceEvent> get onTimelineEvent => onEvent('Timeline');
  // TODO(johnmccutchan): Add FlutterView events.

  // Listen for a specific event name.
  Stream<ServiceEvent> onEvent(String streamId) {
    _streamListen(streamId);
    return _getEventController(streamId).stream;
  }

  Future<Map<String, dynamic>> _sendRequest(
    String method,
    Map<String, dynamic> params,
  ) {
    return Future.any(<Future<Map<String, dynamic>>>[
      _peer.sendRequest(method, params),
      _connectionError.future,
    ]);
  }

  StreamController<ServiceEvent> _getEventController(String eventName) {
    StreamController<ServiceEvent> controller = _eventControllers[eventName];
    if (controller == null) {
      controller = new StreamController<ServiceEvent>.broadcast();
      _eventControllers[eventName] = controller;
    }
    return controller;
  }

  void _handleStreamNotify(Map<String, dynamic> data) {
    final String streamId = data['streamId'];
    final Map<String, dynamic> eventData = data['event'];
    final Map<String, dynamic> eventIsolate = eventData['isolate'];

    // Log event information.
    printTrace(data.toString());

    ServiceEvent event;
    if (eventIsolate != null) {
      // getFromMap creates the Isolate if necessary.
      final Isolate isolate = vm.getFromMap(eventIsolate);
      event = new ServiceObject._fromMap(isolate, eventData);
      if (event.kind == ServiceEvent.kIsolateExit) {
        vm._isolateCache.remove(isolate.id);
        vm._buildIsolateList();
      } else if (event.kind == ServiceEvent.kIsolateRunnable) {
        // Force reload once the isolate becomes runnable so that we
        // update the root library.
        isolate.reload();
      }
    } else {
      // The event doesn't have an isolate, so it is owned by the VM.
      event = new ServiceObject._fromMap(vm, eventData);
    }
    _getEventController(streamId).add(event);
  }

  Future<Null> _streamListen(String streamId) async {
    if (!_listeningFor.contains(streamId)) {
      _listeningFor.add(streamId);
      await _sendRequest('streamListen', <String, dynamic>{ 'streamId': streamId });
    }
  }

  /// Reloads the VM.
  Future<VM> getVM() {
    return _vm.reload();
  }

  Future<Null> waitForViews({int attempts = 5, int attemptSeconds = 1}) async {
    await vm.refreshViews();
    for (int i = 0; (vm.firstView == null) && (i < attempts); i++) {
      // If the VM doesn't yet have a view, wait for one to show up.
      printTrace('Waiting for Flutter view');
      await new Future<Null>.delayed(new Duration(seconds: attemptSeconds));
      await vm.refreshViews();
    }
  }
}

/// An error that is thrown when constructing/updating a service object.
class VMServiceObjectLoadError {
  VMServiceObjectLoadError(this.message, this.map);
  final String message;
  final Map<String, dynamic> map;
}

bool _isServiceMap(Map<String, dynamic> m) {
  return (m != null) && (m['type'] != null);
}
bool _hasRef(String type) => (type != null) && type.startsWith('@');
String _stripRef(String type) => _hasRef(type) ? type.substring(1) : type;

/// Given a raw response from the service protocol and a [ServiceObjectOwner],
/// recursively walk the response and replace values that are service maps with
/// actual [ServiceObject]s. During the upgrade the owner is given a chance
/// to return a cached / canonicalized object.
void _upgradeCollection(dynamic collection,
                        ServiceObjectOwner owner) {
  if (collection is ServiceMap) {
    return;
  }
  if (collection is Map<String, dynamic>) {
    _upgradeMap(collection, owner);
  } else if (collection is List) {
    _upgradeList(collection, owner);
  }
}

void _upgradeMap(Map<String, dynamic> map, ServiceObjectOwner owner) {
  map.forEach((String k, dynamic v) {
    if ((v is Map<String, dynamic>) && _isServiceMap(v)) {
      map[k] = owner.getFromMap(v);
    } else if (v is List) {
      _upgradeList(v, owner);
    } else if (v is Map<String, dynamic>) {
      _upgradeMap(v, owner);
    }
  });
}

void _upgradeList(List<dynamic> list, ServiceObjectOwner owner) {
  for (int i = 0; i < list.length; i++) {
    final dynamic v = list[i];
    if ((v is Map<String, dynamic>) && _isServiceMap(v)) {
      list[i] = owner.getFromMap(v);
    } else if (v is List) {
      _upgradeList(v, owner);
    } else if (v is Map<String, dynamic>) {
      _upgradeMap(v, owner);
    }
  }
}

/// Base class of all objects received over the service protocol.
abstract class ServiceObject {
  ServiceObject._empty(this._owner);

  /// Factory constructor given a [ServiceObjectOwner] and a service map,
  /// upgrade the map into a proper [ServiceObject]. This function always
  /// returns a new instance and does not interact with caches.
  factory ServiceObject._fromMap(ServiceObjectOwner owner,
                                 Map<String, dynamic> map) {
    if (map == null)
      return null;

    if (!_isServiceMap(map))
      throw new VMServiceObjectLoadError('Expected a service map', map);

    final String type = _stripRef(map['type']);

    ServiceObject serviceObject;
    switch (type) {
      case 'Event':
        serviceObject = new ServiceEvent._empty(owner);
      break;
      case 'FlutterView':
        serviceObject = new FlutterView._empty(owner.vm);
      break;
      case 'Isolate':
        serviceObject = new Isolate._empty(owner.vm);
      break;
    }
    // If we don't have a model object for this service object type, as a
    // fallback return a ServiceMap object.
    serviceObject ??= new ServiceMap._empty(owner);
    // We have now constructed an empty service object, call update to populate it.
    serviceObject.update(map);
    return serviceObject;
  }

  final ServiceObjectOwner _owner;
  ServiceObjectOwner get owner => _owner;

  /// The id of this object.
  String get id => _id;
  String _id;

  /// The user-level type of this object.
  String get type => _type;
  String _type;

  /// The vm-level type of this object. Usually the same as [type].
  String get vmType => _vmType;
  String _vmType;

  /// Is it safe to cache this object?
  bool _canCache = false;
  bool get canCache => _canCache;

  /// Has this object been fully loaded?
  bool get loaded => _loaded;
  bool _loaded = false;

  /// Is this object immutable after it is [loaded]?
  bool get immutable => false;

  String get name => _name;
  String _name;

  String get vmName => _vmName;
  String _vmName;

  /// If this is not already loaded, load it. Otherwise reload.
  Future<ServiceObject> load() async {
    if (loaded) {
      return this;
    }
    return reload();
  }

  /// Fetch this object from vmService and return the response directly.
  Future<Map<String, dynamic>> _fetchDirect() {
    final Map<String, dynamic> params = <String, dynamic>{
      'objectId': id,
    };
    return _owner.isolate.invokeRpcRaw('getObject', params: params);
  }

  Future<ServiceObject> _inProgressReload;
  /// Reload the service object (if possible).
  Future<ServiceObject> reload() async {
    final bool hasId = (id != null) && (id != '');
    final bool isVM = this is VM;
    // We should always reload the VM.
    // We can't reload objects without an id.
    // We shouldn't reload an immutable and already loaded object.
    final bool skipLoad = !isVM && (!hasId || (immutable && loaded));
    if (skipLoad) {
      return this;
    }

    if (_inProgressReload == null) {
      final Completer<ServiceObject> completer = new Completer<ServiceObject>();
      _inProgressReload = completer.future;

      try {
        final Map<String, dynamic> response = await _fetchDirect();
        if (_stripRef(response['type']) == 'Sentinel') {
          // An object may have been collected.
          completer.complete(new ServiceObject._fromMap(owner, response));
        } else {
          update(response);
          completer.complete(this);
        }
      } catch (e, st) {
        completer.completeError(e, st);
      }
      _inProgressReload = null;
    }

    return await _inProgressReload;
  }

  /// Update [this] using [map] as a source. [map] can be a service reference.
  void update(Map<String, dynamic> map) {
    // Don't allow the type to change on an object update.
    final bool mapIsRef = _hasRef(map['type']);
    final String mapType = _stripRef(map['type']);

    if ((_type != null) && (_type != mapType)) {
      throw new VMServiceObjectLoadError('ServiceObject types must not change',
                                         map);
    }
    _type = mapType;
    _vmType = map.containsKey('_vmType') ? _stripRef(map['_vmType']) : _type;

    _canCache = map['fixedId'] == true;
    if ((_id != null) && (_id != map['id']) && _canCache) {
      throw new VMServiceObjectLoadError('ServiceObject id changed', map);
    }
    _id = map['id'];

    // Copy name properties.
    _name = map['name'];
    _vmName = map.containsKey('_vmName') ? map['_vmName'] : _name;

    // We have now updated all common properties, let the subclasses update
    // their specific properties.
    _update(map, mapIsRef);
  }

  /// Implemented by subclasses to populate their model.
  void _update(Map<String, dynamic> map, bool mapIsRef);
}

class ServiceEvent extends ServiceObject {
  /// The possible 'kind' values.
  static const String kVMUpdate               = 'VMUpdate';
  static const String kIsolateStart           = 'IsolateStart';
  static const String kIsolateRunnable        = 'IsolateRunnable';
  static const String kIsolateExit            = 'IsolateExit';
  static const String kIsolateUpdate          = 'IsolateUpdate';
  static const String kIsolateReload          = 'IsolateReload';
  static const String kIsolateSpawn           = 'IsolateSpawn';
  static const String kServiceExtensionAdded  = 'ServiceExtensionAdded';
  static const String kPauseStart             = 'PauseStart';
  static const String kPauseExit              = 'PauseExit';
  static const String kPauseBreakpoint        = 'PauseBreakpoint';
  static const String kPauseInterrupted       = 'PauseInterrupted';
  static const String kPauseException         = 'PauseException';
  static const String kPausePostRequest       = 'PausePostRequest';
  static const String kNone                   = 'None';
  static const String kResume                 = 'Resume';
  static const String kBreakpointAdded        = 'BreakpointAdded';
  static const String kBreakpointResolved     = 'BreakpointResolved';
  static const String kBreakpointRemoved      = 'BreakpointRemoved';
  static const String kGraph                  = '_Graph';
  static const String kGC                     = 'GC';
  static const String kInspect                = 'Inspect';
  static const String kDebuggerSettingsUpdate = '_DebuggerSettingsUpdate';
  static const String kConnectionClosed       = 'ConnectionClosed';
  static const String kLogging                = '_Logging';
  static const String kExtension              = 'Extension';

  ServiceEvent._empty(ServiceObjectOwner owner) : super._empty(owner);

  String _kind;
  String get kind => _kind;
  DateTime _timestamp;
  DateTime get timestmap => _timestamp;
  String _extensionKind;
  String get extensionKind => _extensionKind;
  Map<String, dynamic> _extensionData;
  Map<String, dynamic> get extensionData => _extensionData;
  List<Map<String, dynamic>> _timelineEvents;
  List<Map<String, dynamic>> get timelineEvents => _timelineEvents;

  @override
  void _update(Map<String, dynamic> map, bool mapIsRef) {
    _loaded = true;
    _upgradeCollection(map, owner);
    _kind = map['kind'];
    assert(map['isolate'] == null || owner == map['isolate']);
    _timestamp =
        new DateTime.fromMillisecondsSinceEpoch(map['timestamp']);
    if (map['extensionKind'] != null) {
      _extensionKind = map['extensionKind'];
      _extensionData = map['extensionData'];
    }
    _timelineEvents = map['timelineEvents'];
  }

  bool get isPauseEvent {
    return kind == kPauseStart ||
           kind == kPauseExit ||
           kind == kPauseBreakpoint ||
           kind == kPauseInterrupted ||
           kind == kPauseException ||
           kind == kPausePostRequest ||
           kind == kNone;
  }
}

/// A ServiceObjectOwner is either a [VM] or an [Isolate]. Owners can cache
/// and/or canonicalize service objects received over the wire.
abstract class ServiceObjectOwner extends ServiceObject {
  ServiceObjectOwner._empty(ServiceObjectOwner owner) : super._empty(owner);

  /// Returns the owning VM.
  VM get vm => null;

  /// Returns the owning isolate (if any).
  Isolate get isolate => null;

  /// Returns the vmService connection.
  VMService get vmService => null;

  /// Builds a [ServiceObject] corresponding to the [id] from [map].
  /// The result may come from the cache. The result will not necessarily
  /// be [loaded].
  ServiceObject getFromMap(Map<String, dynamic> map);
}

/// There is only one instance of the VM class. The VM class owns [Isolate]
/// and [FlutterView] objects.
class VM extends ServiceObjectOwner {
  VM._empty(this._vmService) : super._empty(null);

  /// Connection to the VMService.
  final VMService _vmService;
  @override
  VMService get vmService => _vmService;

  @override
  VM get vm => this;

  @override
  Future<Map<String, dynamic>> _fetchDirect() async {
    return invokeRpcRaw('getVM');
  }

  @override
  void _update(Map<String, dynamic> map, bool mapIsRef) {
    if (mapIsRef)
      return;

    // Upgrade the collection. A side effect of this call is that any new
    // isolates in the map are created and added to the isolate cache.
    _upgradeCollection(map, this);
    _loaded = true;

    // TODO(johnmccutchan): Extract any properties we care about here.
    _pid = map['pid'];
    if (map['_heapAllocatedMemoryUsage'] != null) {
      _heapAllocatedMemoryUsage = map['_heapAllocatedMemoryUsage'];
    }
    _maxRSS = map['_maxRSS'];

    // Remove any isolates which are now dead from the isolate cache.
    _removeDeadIsolates(map['isolates']);
  }

  final Map<String, ServiceObject> _cache = <String,ServiceObject>{};
  final Map<String,Isolate> _isolateCache = <String,Isolate>{};

  /// The list of live isolates, ordered by isolate start time.
  final List<Isolate> isolates = <Isolate>[];

  /// The set of live views.
  final Map<String, FlutterView> _viewCache = <String, FlutterView>{};

  /// The pid of the VM's process.
  int _pid;
  int get pid => _pid;

  /// The number of bytes allocated (e.g. by malloc) in the native heap.
  int _heapAllocatedMemoryUsage;
  int get heapAllocatedMemoryUsage {
    return _heapAllocatedMemoryUsage == null ? 0 : _heapAllocatedMemoryUsage;
  }

  /// The peak resident set size for the process.
  int _maxRSS;
  int get maxRSS => _maxRSS == null ? 0 : _maxRSS;

  int _compareIsolates(Isolate a, Isolate b) {
    final DateTime aStart = a.startTime;
    final DateTime bStart = b.startTime;
    if (aStart == null) {
      if (bStart == null) {
        return 0;
      } else {
        return 1;
      }
    }
    if (bStart == null) {
      return -1;
    }
    return aStart.compareTo(bStart);
  }

  void _buildIsolateList() {
    final List<Isolate> isolateList = _isolateCache.values.toList();
    isolateList.sort(_compareIsolates);
    isolates.clear();
    isolates.addAll(isolateList);
  }

  void _removeDeadIsolates(List<Isolate> newIsolates) {
    // Build a set of new isolates.
    final Set<String> newIsolateSet = new Set<String>();
    for (Isolate iso in newIsolates)
      newIsolateSet.add(iso.id);

    // Remove any old isolates which no longer exist.
    final List<String> toRemove = <String>[];
    _isolateCache.forEach((String id, _) {
      if (!newIsolateSet.contains(id)) {
        toRemove.add(id);
      }
    });
    toRemove.forEach(_isolateCache.remove);
    _buildIsolateList();
  }

  @override
  ServiceObject getFromMap(Map<String, dynamic> map) {
    if (map == null) {
      return null;
    }
    final String type = _stripRef(map['type']);
    if (type == 'VM') {
      // Update this VM object.
      update(map);
      return this;
    }

    final String mapId = map['id'];

    switch (type) {
      case 'Isolate': {
        // Check cache.
        Isolate isolate = _isolateCache[mapId];
        if (isolate == null) {
          // Add new isolate to the cache.
          isolate = new ServiceObject._fromMap(this, map);
          _isolateCache[mapId] = isolate;
          _buildIsolateList();

          // Eagerly load the isolate.
          isolate.load().catchError((dynamic e, StackTrace stack) {
            printTrace('Eagerly loading an isolate failed: $e\n$stack');
          });
        } else {
          // Existing isolate, update data.
          isolate.update(map);
        }
        return isolate;
      }
      break;
      case 'FlutterView': {
        FlutterView view = _viewCache[mapId];
        if (view == null) {
          // Add new view to the cache.
          view = new ServiceObject._fromMap(this, map);
          _viewCache[mapId] = view;
        } else {
          view.update(map);
        }
        return view;
      }
      break;
      default:
        throw new VMServiceObjectLoadError(
            'VM.getFromMap called for something other than an isolate', map);
    }
  }

  // This function does not reload the isolate if it's found in the cache.
  Future<Isolate> getIsolate(String isolateId) {
    if (!loaded) {
      // Trigger a VM load, then get the isolate. Ignore any errors.
      return load().then<Isolate>((ServiceObject serviceObject) => getIsolate(isolateId)).catchError((dynamic error) => null);
    }
    return new Future<Isolate>.value(_isolateCache[isolateId]);
  }

  /// Invoke the RPC and return the raw response.
  ///
  /// If `timeoutFatal` is false, then a timeout will result in a null return
  /// value. Otherwise, it results in an exception.
  Future<Map<String, dynamic>> invokeRpcRaw(String method, {
    Map<String, dynamic> params: const <String, dynamic>{},
    Duration timeout,
    bool timeoutFatal: true,
  }) async {
    printTrace('$method: $params');

    assert(params != null);
    timeout ??= _vmService._requestTimeout;
    try {
      final Map<String, dynamic> result = await _vmService
          ._sendRequest(method, params)
          .timeout(timeout);
      return result;
    } on TimeoutException {
      printTrace('Request to Dart VM Service timed out: $method($params)');
      if (timeoutFatal)
        throw new TimeoutException('Request to Dart VM Service timed out: $method($params)');
      return null;
    } on WebSocketChannelException catch (error) {
      throwToolExit('Error connecting to observatory: $error');
      return null;
    } on rpc.RpcException catch (error) {
      printError('Error ${error.code} received from application: ${error.message}');
      printTrace('${error.data}');
      return null;
    }
  }

  /// Invoke the RPC and return a [ServiceObject] response.
  Future<ServiceObject> invokeRpc(String method, {
    Map<String, dynamic> params: const <String, dynamic>{},
    Duration timeout,
  }) async {
    final Map<String, dynamic> response = await invokeRpcRaw(
      method,
      params: params,
      timeout: timeout,
    );
    final ServiceObject serviceObject = new ServiceObject._fromMap(this, response);
    if ((serviceObject != null) && (serviceObject._canCache)) {
      final String serviceObjectId = serviceObject.id;
      _cache.putIfAbsent(serviceObjectId, () => serviceObject);
    }
    return serviceObject;
  }

  /// Create a new development file system on the device.
  Future<Map<String, dynamic>> createDevFS(String fsName) {
    return invokeRpcRaw('_createDevFS', params: <String, dynamic> { 'fsName': fsName });
  }

  /// List the development file system son the device.
  Future<List<String>> listDevFS() async {
    return (await invokeRpcRaw('_listDevFS'))['fsNames'];
  }

  // Write one file into a file system.
  Future<Map<String, dynamic>> writeDevFSFile(String fsName, {
    @required String path,
    @required List<int> fileContents
  }) {
    assert(path != null);
    assert(fileContents != null);
    return invokeRpcRaw(
      '_writeDevFSFile',
      params: <String, dynamic>{
        'fsName': fsName,
        'path': path,
        'fileContents': BASE64.encode(fileContents),
      },
    );
  }

  // Read one file from a file system.
  Future<List<int>> readDevFSFile(String fsName, String path) async {
    final Map<String, dynamic> response = await invokeRpcRaw(
      '_readDevFSFile',
      params: <String, dynamic>{
        'fsName': fsName,
        'path': path,
      },
    );
    return BASE64.decode(response['fileContents']);
  }

  /// The complete list of a file system.
  Future<List<String>> listDevFSFiles(String fsName) async {
    return (await invokeRpcRaw('_listDevFSFiles', params: <String, dynamic>{ 'fsName': fsName }))['files'];
  }

  /// Delete an existing file system.
  Future<Map<String, dynamic>> deleteDevFS(String fsName) {
    return invokeRpcRaw('_deleteDevFS', params: <String, dynamic>{ 'fsName': fsName });
  }

  Future<ServiceMap> runInView(String viewId,
                               Uri main,
                               Uri packages,
                               Uri assetsDirectory) {
    // TODO(goderbauer): Transfer Uri (instead of file path) when remote end supports it.
    return invokeRpc('_flutter.runInView',
                    params: <String, dynamic> {
                      'viewId': viewId,
                      'mainScript': main.toFilePath(windows: false),
                      'packagesFile': packages.toFilePath(windows: false),
                      'assetDirectory': assetsDirectory.toFilePath(windows: false)
                    });
  }

  Future<Map<String, dynamic>> clearVMTimeline() {
    return invokeRpcRaw('_clearVMTimeline');
  }

  Future<Map<String, dynamic>> setVMTimelineFlags(List<String> recordedStreams) {
    assert(recordedStreams != null);
    return invokeRpcRaw(
      '_setVMTimelineFlags',
      params: <String, dynamic>{
        'recordedStreams': recordedStreams,
      },
    );
  }

  Future<Map<String, dynamic>> getVMTimeline() {
    return invokeRpcRaw('_getVMTimeline', timeout: kLongRequestTimeout);
  }

  Future<Null> refreshViews() async {
    _viewCache.clear();
    await vmService.vm.invokeRpc('_flutter.listViews', timeout: kLongRequestTimeout);
  }

  Iterable<FlutterView> get views => _viewCache.values;

  FlutterView get firstView {
    return _viewCache.values.isEmpty ? null : _viewCache.values.first;
  }

  List<FlutterView> allViewsWithName(String isolateFilter) {
    if (_viewCache.values.isEmpty)
      return null;
    return _viewCache.values.where(
      (FlutterView v) => v.uiIsolate.name.contains(isolateFilter)
    ).toList();
  }
}

class HeapSpace extends ServiceObject {
  HeapSpace._empty(ServiceObjectOwner owner) : super._empty(owner);

  int _used = 0;
  int _capacity = 0;
  int _external = 0;
  int _collections = 0;
  double _totalCollectionTimeInSeconds = 0.0;
  double _averageCollectionPeriodInMillis = 0.0;

  int get used => _used;
  int get capacity => _capacity;
  int get external => _external;

  Duration get avgCollectionTime {
    final double mcs = _totalCollectionTimeInSeconds *
      Duration.MICROSECONDS_PER_SECOND /
      math.max(_collections, 1);
    return new Duration(microseconds: mcs.ceil());
  }

  Duration get avgCollectionPeriod {
    final double mcs = _averageCollectionPeriodInMillis *
                       Duration.MICROSECONDS_PER_MILLISECOND;
    return new Duration(microseconds: mcs.ceil());
  }

  @override
  void _update(Map<String, dynamic> map, bool mapIsRef) {
    _used = map['used'];
    _capacity = map['capacity'];
    _external = map['external'];
    _collections = map['collections'];
    _totalCollectionTimeInSeconds = map['time'];
    _averageCollectionPeriodInMillis = map['avgCollectionPeriodMillis'];
  }
}

/// A function, field or class along with its source location.
class ProgramElement {
  ProgramElement(this.qualifiedName, this.uri, [this.line, this.column]);

  final String qualifiedName;
  final Uri uri;
  final int line;
  final int column;

  @override
  String toString() {
    if (line == null)
      return '$qualifiedName ($uri)';
    else
      return '$qualifiedName ($uri:$line)';
  }
}

/// An isolate running inside the VM. Instances of the Isolate class are always
/// canonicalized.
class Isolate extends ServiceObjectOwner {
  Isolate._empty(ServiceObjectOwner owner) : super._empty(owner);

  @override
  VM get vm => owner;

  @override
  VMService get vmService => vm.vmService;

  @override
  Isolate get isolate => this;

  DateTime startTime;

  /// The last pause event delivered to the isolate. If the isolate is running,
  /// this will be a resume event.
  ServiceEvent pauseEvent;

  final Map<String, ServiceObject> _cache = <String, ServiceObject>{};

  HeapSpace _newSpace;
  HeapSpace _oldSpace;

  HeapSpace get newSpace => _newSpace;
  HeapSpace get oldSpace => _oldSpace;

  @override
  ServiceObject getFromMap(Map<String, dynamic> map) {
    if (map == null)
      return null;
    final String mapType = _stripRef(map['type']);
    if (mapType == 'Isolate') {
      // There are sometimes isolate refs in ServiceEvents.
      return vm.getFromMap(map);
    }

    final String mapId = map['id'];
    ServiceObject serviceObject = (mapId != null) ? _cache[mapId] : null;
    if (serviceObject != null) {
      serviceObject.update(map);
      return serviceObject;
    }
    // Build the object from the map directly.
    serviceObject = new ServiceObject._fromMap(this, map);
    if ((serviceObject != null) && serviceObject.canCache)
      _cache[mapId] = serviceObject;
    return serviceObject;
  }

  @override
  Future<Map<String, dynamic>> _fetchDirect() {
    return invokeRpcRaw('getIsolate');
  }

  /// Invoke the RPC and return the raw response.
  Future<Map<String, dynamic>> invokeRpcRaw(String method, {
    Map<String, dynamic> params,
    Duration timeout,
    bool timeoutFatal: true,
  }) {
    // Inject the 'isolateId' parameter.
    if (params == null) {
      params = <String, dynamic>{
        'isolateId': id
      };
    } else {
      params['isolateId'] = id;
    }
    return vm.invokeRpcRaw(method, params: params, timeout: timeout, timeoutFatal: timeoutFatal);
  }

  /// Invoke the RPC and return a ServiceObject response.
  Future<ServiceObject> invokeRpc(String method, Map<String, dynamic> params) async {
    return getFromMap(await invokeRpcRaw(method, params: params));
  }

  void _updateHeaps(Map<String, dynamic> map, bool mapIsRef) {
    _newSpace ??= new HeapSpace._empty(this);
    _newSpace._update(map['new'], mapIsRef);
    _oldSpace ??= new HeapSpace._empty(this);
    _oldSpace._update(map['old'], mapIsRef);
  }

  @override
  void _update(Map<String, dynamic> map, bool mapIsRef) {
    if (mapIsRef)
      return;
    _loaded = true;

    final int startTimeMillis = map['startTime'];
    startTime = new DateTime.fromMillisecondsSinceEpoch(startTimeMillis);

    _upgradeCollection(map, this);

    pauseEvent = map['pauseEvent'];

    _updateHeaps(map['_heaps'], mapIsRef);
  }

  static const int kIsolateReloadBarred = 1005;

  Future<Map<String, dynamic>> reloadSources(
      { bool pause: false,
        Uri rootLibUri,
        Uri packagesUri}) async {
    try {
      final Map<String, dynamic> arguments = <String, dynamic>{
        'pause': pause
      };
      // TODO(goderbauer): Transfer Uri (instead of file path) when remote end supports it.
      //     Note: Despite the name, `rootLibUri` and `packagesUri` expect file paths.
      if (rootLibUri != null) {
        arguments['rootLibUri'] = rootLibUri.toFilePath(windows: false);
      }
      if (packagesUri != null) {
        arguments['packagesUri'] = packagesUri.toFilePath(windows: false);
      }
      final Map<String, dynamic> response = await invokeRpcRaw('_reloadSources', params: arguments);
      return response;
    } on rpc.RpcException catch (e) {
      return new Future<Map<String, dynamic>>.error(<String, dynamic>{
        'code': e.code,
        'message': e.message,
        'data': e.data,
      });
    }
  }

  Future<Map<String, dynamic>> getObject(Map<String, dynamic> objectRef) {
    return invokeRpcRaw('getObject',
                        params: <String, dynamic>{'objectId': objectRef['id']});
  }

  Future<ProgramElement> _describeElement(Map<String, dynamic> elementRef) async {
    String name = elementRef['name'];
    Map<String, dynamic> owner = elementRef['owner'];
    while (owner != null) {
      final String ownerType = owner['type'];
      if (ownerType == 'Library' || ownerType == '@Library')
        break;
      final String ownerName = owner['name'];
      name = '$ownerName.$name';
      owner = owner['owner'];
    }

    final Map<String, dynamic> fullElement = await getObject(elementRef);
    final Map<String, dynamic> location = fullElement['location'];
    final int tokenPos = location['tokenPos'];
    final Map<String, dynamic> script = await getObject(location['script']);

    // The engine's tag handler doesn't seem to create proper URIs.
    Uri uri = Uri.parse(script['uri']);
    if (uri.scheme == '')
      uri = uri.replace(scheme: 'file');

    // See https://github.com/dart-lang/sdk/blob/master/runtime/vm/service/service.md
    for (List<int> lineTuple in script['tokenPosTable']) {
      final int line = lineTuple[0];
      for (int i = 1; i < lineTuple.length; i += 2) {
        if (lineTuple[i] == tokenPos) {
          final int column = lineTuple[i + 1];
          return new ProgramElement(name, uri, line, column);
        }
      }
    }
    return new ProgramElement(name, uri);
  }

  // Lists program elements changed in the most recent reload that have not
  // since executed.
  Future<List<ProgramElement>> getUnusedChangesInLastReload() async {
    final Map<String, dynamic> response =
      await invokeRpcRaw('_getUnusedChangesInLastReload');
    final List<Future<ProgramElement>> unusedElements =
      <Future<ProgramElement>>[];
    for (Map<String, dynamic> element in response['unused'])
      unusedElements.add(_describeElement(element));
    return Future.wait(unusedElements);
  }

  /// Resumes the isolate.
  Future<Map<String, dynamic>> resume() {
    return invokeRpcRaw('resume');
  }

  // Flutter extension methods.

  // Invoke a flutter extension method, if the flutter extension is not
  // available, returns null.
  Future<Map<String, dynamic>> invokeFlutterExtensionRpcRaw(
    String method, {
      Map<String, dynamic> params,
      Duration timeout,
      bool timeoutFatal: true,
    }
  ) async {
    try {
      return await invokeRpcRaw(method, params: params, timeout: timeout, timeoutFatal: timeoutFatal);
    } on rpc.RpcException catch (e) {
      // If an application is not using the framework
      if (e.code == rpc_error_code.METHOD_NOT_FOUND)
        return null;
      rethrow;
    }
  }

  // Debug dump extension methods.

  Future<Map<String, dynamic>> flutterDebugDumpApp() {
    return invokeFlutterExtensionRpcRaw('ext.flutter.debugDumpApp', timeout: kLongRequestTimeout);
  }

  Future<Map<String, dynamic>> flutterDebugDumpRenderTree() {
    return invokeFlutterExtensionRpcRaw('ext.flutter.debugDumpRenderTree', timeout: kLongRequestTimeout);
  }

  Future<Map<String, dynamic>> flutterDebugDumpLayerTree() {
    return invokeFlutterExtensionRpcRaw('ext.flutter.debugDumpLayerTree', timeout: kLongRequestTimeout);
  }

  Future<Map<String, dynamic>> flutterDebugDumpSemanticsTreeInTraversalOrder() {
    return invokeFlutterExtensionRpcRaw('ext.flutter.debugDumpSemanticsTreeInTraversalOrder', timeout: kLongRequestTimeout);
  }

  Future<Map<String, dynamic>> flutterDebugDumpSemanticsTreeInInverseHitTestOrder() {
    return invokeFlutterExtensionRpcRaw('ext.flutter.debugDumpSemanticsTreeInInverseHitTestOrder', timeout: kLongRequestTimeout);
  }

  Future<Map<String, dynamic>> _flutterToggle(String name) async {
    Map<String, dynamic> state = await invokeFlutterExtensionRpcRaw('ext.flutter.$name');
    if (state != null && state.containsKey('enabled') && state['enabled'] is String) {
      state = await invokeFlutterExtensionRpcRaw(
        'ext.flutter.$name',
        params: <String, dynamic>{ 'enabled': state['enabled'] == 'true' ? 'false' : 'true' },
        timeout: const Duration(milliseconds: 150),
        timeoutFatal: false,
      );
    }
    return state;
  }

  Future<Map<String, dynamic>> flutterToggleDebugPaintSizeEnabled() => _flutterToggle('debugPaint');

  Future<Map<String, dynamic>> flutterTogglePerformanceOverlayOverride() => _flutterToggle('showPerformanceOverlay');

  Future<Map<String, dynamic>> flutterToggleWidgetInspector() => _flutterToggle('debugWidgetInspector');

  Future<Null> flutterDebugAllowBanner(bool show) async {
    await invokeFlutterExtensionRpcRaw(
      'ext.flutter.debugAllowBanner',
      params: <String, dynamic>{ 'enabled': show ? 'true' : 'false' },
      timeout: const Duration(milliseconds: 150),
      timeoutFatal: false,
    );
  }

  // Reload related extension methods.
  Future<Map<String, dynamic>> flutterReassemble() async {
    return await invokeFlutterExtensionRpcRaw(
      'ext.flutter.reassemble',
      timeout: kShortRequestTimeout,
      timeoutFatal: true,
    );
  }

  Future<bool> flutterFrameworkPresent() async {
    return await invokeFlutterExtensionRpcRaw('ext.flutter.frameworkPresent') != null;
  }

  Future<Map<String, dynamic>> uiWindowScheduleFrame() async {
    return await invokeFlutterExtensionRpcRaw('ext.ui.window.scheduleFrame');
  }

  Future<Map<String, dynamic>> flutterEvictAsset(String assetPath) async {
    return await invokeFlutterExtensionRpcRaw('ext.flutter.evict',
      params: <String, dynamic>{
        'value': assetPath,
      }
    );
  }

  // Application control extension methods.
  Future<Map<String, dynamic>> flutterExit() async {
    return await invokeFlutterExtensionRpcRaw(
      'ext.flutter.exit',
      timeout: const Duration(seconds: 2),
      timeoutFatal: false,
    );
  }

  Future<String> flutterPlatformOverride([String platform]) async {
    final Map<String, String> result = await invokeFlutterExtensionRpcRaw(
      'ext.flutter.platformOverride',
      params: platform != null ? <String, dynamic>{ 'value': platform } : <String, String>{},
      timeout: const Duration(seconds: 5),
      timeoutFatal: false,
    );
    if (result != null && result['value'] is String)
      return result['value'];
    return 'unknown';
  }

  @override
  String toString() => 'Isolate $id';
}

class ServiceMap extends ServiceObject implements Map<String, dynamic> {
  ServiceMap._empty(ServiceObjectOwner owner) : super._empty(owner);

  final Map<String, dynamic> _map = <String, dynamic>{};

  @override
  void _update(Map<String, dynamic> map, bool mapIsRef) {
    _loaded = !mapIsRef;
    _upgradeCollection(map, owner);
    _map.clear();
    _map.addAll(map);
  }

  // Forward Map interface calls.
  @override
  void addAll(Map<String, dynamic> other) => _map.addAll(other);
  @override
  void clear() => _map.clear();
  @override
  bool containsValue(dynamic v) => _map.containsValue(v);
  @override
  bool containsKey(Object k) => _map.containsKey(k);
  @override
  void forEach(void f(String key, dynamic value)) => _map.forEach(f);
  @override
  dynamic putIfAbsent(String key, dynamic ifAbsent()) => _map.putIfAbsent(key, ifAbsent);
  @override
  void remove(Object key) => _map.remove(key);
  @override
  dynamic operator [](Object k) => _map[k];
  @override
  void operator []=(String k, dynamic v) => _map[k] = v;
  @override
  bool get isEmpty => _map.isEmpty;
  @override
  bool get isNotEmpty => _map.isNotEmpty;
  @override
  Iterable<String> get keys => _map.keys;
  @override
  Iterable<dynamic> get values => _map.values;
  @override
  int get length => _map.length;
  @override
  String toString() => _map.toString();
}

/// Peered to a Android/iOS FlutterView widget on a device.
class FlutterView extends ServiceObject {
  FlutterView._empty(ServiceObjectOwner owner) : super._empty(owner);

  Isolate _uiIsolate;
  Isolate get uiIsolate => _uiIsolate;

  @override
  void _update(Map<String, dynamic> map, bool mapIsRef) {
    _loaded = !mapIsRef;
    _upgradeCollection(map, owner);
    _uiIsolate = map['isolate'];
  }

  // TODO(johnmccutchan): Report errors when running failed.
  Future<Null> runFromSource(Uri entryUri,
                             Uri packagesUri,
                             Uri assetsDirectoryUri) async {
    final String viewId = id;
    // When this completer completes the isolate is running.
    final Completer<Null> completer = new Completer<Null>();
    final StreamSubscription<ServiceEvent> subscription =
      owner.vm.vmService.onIsolateEvent.listen((ServiceEvent event) {
      // TODO(johnmccutchan): Listen to the debug stream and catch initial
      // launch errors.
      if (event.kind == ServiceEvent.kIsolateRunnable) {
        printTrace('Isolate is runnable.');
        if (!completer.isCompleted)
          completer.complete(null);
      }
    });
    await owner.vm.runInView(viewId,
                             entryUri,
                             packagesUri,
                             assetsDirectoryUri);
    await completer.future;
    await owner.vm.refreshViews();
    await subscription.cancel();
  }

  Future<Null> setAssetDirectory(Uri assetsDirectory) async {
    assert(assetsDirectory != null);
    await owner.vmService.vm.invokeRpc('_flutter.setAssetBundlePath',
        params: <String, dynamic>{
          'viewId': id,
          'assetDirectory': assetsDirectory.toFilePath(windows: false)
        });
  }

  bool get hasIsolate => _uiIsolate != null;

  Future<Null> flushUIThreadTasks() async {
    await owner.vm.invokeRpcRaw('_flutter.flushUIThreadTasks');
  }

  @override
  String toString() => id;
}
