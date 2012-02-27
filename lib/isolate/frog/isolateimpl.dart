// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/** Implementation of [Isolate2]. */
class _Isolate2Impl implements Isolate2 {
  SendPort sendPort;

  _Isolate2Impl(this.sendPort);
}

/**
 * A native object that is shared across isolates. This object is visible to all
 * isolates running on the same worker (either UI or background web worker).
 *
 * This is code that is intended to 'escape' the isolate boundaries in order to
 * implement the semantics of isolates in JavaScript. Without this we would have
 * been forced to implement more code (including the top-level event loop) in
 * JavaScript itself.
 */
GlobalState get globalState() native "return \$globalState;";
set globalState(GlobalState val) native "\$globalState = val;";

void fillStatics(context) native @"""
  $globals = context.isolateStatics;
  $static_init();
""";

/** Global state associated with the current worker. See [globalState]. */
// TODO(sigmund): split in multiple classes: global, thread, main-worker states?
class GlobalState {

  /** Next available isolate id. */
  int nextIsolateId = 0;

  /** Worker id associated with this worker. */
  int currentWorkerId = 0;

  /**
   * Next available worker id. Only used by the main worker to assign a unique
   * id to each worker created by it.
   */
  int nextWorkerId = 1;

  /** Context for the currently running [Isolate]. */
  IsolateContext currentContext = null;

  /** Context for the root [Isolate] that first run in this worker. */
  IsolateContext rootContext = null;

  /** The top-level event loop. */
  EventLoop topEventLoop;

  /** Whether this program is running in a background worker. */
  bool isWorker;

  /** Whether this program is running in a UI worker. */
  bool inWindow;

  /** Whether we support spawning workers. */
  bool supportsWorkers;

  /**
   * Whether to use web workers when implementing isolates. Set to false for
   * debugging/testing.
   */
  bool get useWorkers() => supportsWorkers;

  /**
   * Whether to use the web-worker JSON-based message serialization protocol. By
   * default this is only used with web workers. For debugging, you can force
   * using this protocol by changing this field value to [true].
   */
  bool get needSerialization() => useWorkers;

  /**
   * Registry of isolates. Isolates must be registered if, and only if, receive
   * ports are alive.  Normally no open receive-ports means that the isolate is
   * dead, but DOM callbacks could resurrect it.
   */
  Map<int, IsolateContext> isolates;

  /** Reference to the main worker. */
  MainWorker mainWorker;

  /** Registry of active workers. Only used in the main worker. */
  Map<int, Dynamic> workers;

  GlobalState() {
    topEventLoop = new EventLoop();
    isolates = {};
    workers = {};
    mainWorker = new MainWorker();
    _nativeInit();
  }

  void _nativeInit() native @"""
    this.isWorker = typeof ($globalThis['importScripts']) != 'undefined';
    this.inWindow = typeof(window) !== 'undefined';
    this.supportsWorkers = this.isWorker ||
        ((typeof $globalThis['Worker']) != 'undefined');

    // if workers are supported, treat this as a main worker:
    if (this.supportsWorkers) {
      $globalThis.onmessage = function(e) {
        _IsolateNatives._processWorkerMessage(this.mainWorker, e);
      };
    }
  """ {
    // Declare that the native code has a dependency on this fn.
    _IsolateNatives._processWorkerMessage(null, null);
  }

  /**
   * Close the worker running this code, called when there is nothing else to
   * run.
   */
  void closeWorker() {
    if (isWorker) {
      if (!isolates.isEmpty()) return;
      mainWorker.postMessage(
          _serializeMessage({'command': 'close'}));
    } else if (isolates.containsKey(rootContext.id) && workers.isEmpty() &&
               !supportsWorkers && !inWindow) {
      // This should only trigger when running on the command-line.
      // We don't want this check to execute in the browser where the isolate
      // might still be alive due to DOM callbacks.
      throw new Exception("Program exited with open ReceivePorts.");
    }
  }
}

/** Context information tracked for each isolate. */
class IsolateContext {
  /** Current isolate id. */
  int id;

  /** Registry of receive ports currently active on this isolate. */
  Map<int, ReceivePort> ports;

  /** Holds isolate globals (statics and top-level properties). */
  var isolateStatics; // native object containing all globals of an isolate.

  IsolateContext() {
    id = globalState.nextIsolateId++;
    ports = {};
    initGlobals();
  }

  // these are filled lazily the first time the isolate starts running.
  void initGlobals() native 'this.isolateStatics = {};';

  /**
   * Run [code] in the context of the isolate represented by [this]. Note this
   * is called from JavaScript (see $wrap_call in corejs.dart).
   */
  void eval(Function code) {
    var old = globalState.currentContext;
    globalState.currentContext = this;
    this._setGlobals();
    var result = null;
    try {
      result = code();
    } finally {
      globalState.currentContext = old;
      if (old != null) old._setGlobals();
    }
    return result;
  }

  void _setGlobals() native @'$globals = this.isolateStatics;';

  /** Lookup a port registered for this isolate. */
  ReceivePort lookup(int id) => ports[id];

  /** Register a port on this isolate. */
  void register(int portId, ReceivePort port)  {
    if (ports.containsKey(portId)) {
      throw new Exception("Registry: ports must be registered only once.");
    }
    ports[portId] = port;
    globalState.isolates[id] = this; // indicate this isolate is active
  }

  /** Unregister a port on this isolate. */
  void unregister(int portId) {
    ports.remove(portId);
    if (ports.isEmpty()) {
      globalState.isolates.remove(id); // indicate this isolate is not active
    }
  }
}


/** Represent the event loop on a javascript thread (DOM or worker). */
class EventLoop {
  Queue<IsolateEvent> events;

  EventLoop() : events = new Queue<IsolateEvent>();

  void enqueue(isolate, fn, msg) {
    events.addLast(new IsolateEvent(isolate, fn, msg));
  }

  IsolateEvent dequeue() {
    if (events.isEmpty()) return null;
    return events.removeFirst();
  }

  /** Process a single event, if any. */
  bool runIteration() {
    final event = dequeue();
    if (event == null) {
      globalState.closeWorker();
      return false;
    }
    event.process();
    return true;
  }

  /** Function equivalent to [:window.setTimeout:] when available, or null. */
  static Function _wrapSetTimeout() native """
      return typeof window != 'undefined' ?
          function(a, b) { window.setTimeout(a, b); } : undefined;
  """;

  /**
   * Runs multiple iterations of the run-loop. If possible, each iteration is
   * run asynchronously.
   */
  void _runHelper() {
    final setTimeout = _wrapSetTimeout();
    if (setTimeout != null) {
      // Run each iteration from the browser's top event loop.
      void next() {
        if (!runIteration()) return;
        setTimeout(next, 0);
      }
      next();
    } else {
      // Run synchronously until no more iterations are available.
      while (runIteration()) {}
    }
  }

  /**
   * Call [_runHelper] but ensure that worker exceptions are propragated. Note
   * this is called from JavaScript (see $wrap_call in corejs.dart).
   */
  void run() {
    if (!globalState.isWorker) {
      _runHelper();
    } else {
      try {
        _runHelper();
      } catch(var e, var trace) {
        globalState.mainWorker.postMessage(_serializeMessage(
            {'command': 'error', 'msg': '$e\n$trace' }));
      }
    }
  }
}

/** An event in the top-level event queue. */
class IsolateEvent {
  IsolateContext isolate;
  Function fn;
  String message;

  IsolateEvent(this.isolate, this.fn, this.message);

  void process() {
    isolate.eval(fn);
  }
}


/** Default worker. */
class MainWorker {
  int id = 0;
  void postMessage(msg) native "return \$globalThis.postMessage(msg);";
  void set onmessage(f) native "\$globalThis.onmessage = f;";
  void terminate() {}
}

/**
 * A web worker. This type is also defined in 'dart:dom', but we define it here
 * to avoid introducing a dependency from corelib to dom. This definition uses a
 * 'hidden' type (* prefix on the native name) to enforce that the type is
 * defined dynamically only when web workers are actually available.
 */
class _Worker native "*Worker" {
  get id() native "return this.id;";
  void set id(i) native "this.id = i;";
  void set onmessage(f) native "this.onmessage = f;";
  void postMessage(msg) native "return this.postMessage(msg);";
}

final String _SPAWNED_SIGNAL = "spawned";

class _IsolateNatives {

  /** JavaScript-specific implementation to spawn an isolate. */
  static Future<SendPort> spawn(Isolate isolate, bool isLight) {
    Completer<SendPort> completer = new Completer<SendPort>();
    ReceivePort port = new ReceivePort.singleShot();
    port.receive((msg, SendPort replyPort) {
      assert(msg == _SPAWNED_SIGNAL);
      completer.complete(replyPort);
    });

    // TODO(floitsch): throw exception if isolate's class doesn't have a
    // default constructor.
    if (globalState.useWorkers && !isLight) {
      _startWorker(isolate, port.toSendPort());
    } else {
      _startNonWorker(isolate, port.toSendPort());
    }

    return completer.future;
  }

  static SendPort _startWorker(Isolate runnable, SendPort replyPort) {
    var factoryName = _getJSConstructorName(runnable);
    if (globalState.isWorker) {
      globalState.mainWorker.postMessage(_serializeMessage({
          'command': 'spawn-worker',
          'factoryName': factoryName,
          'replyPort': _serializeMessage(replyPort)}));
    } else {
      _spawnWorker(factoryName, _serializeMessage(replyPort));
    }
  }

  /**
   * The src url for the script tag that loaded this code. Used to create
   * JavaScript workers.
   */
  static String get _thisScript() =>
      _thisScriptCache != null ? _thisScriptCache : _computeThisScript();

  static String _thisScriptCache;

  // TODO(sigmund): fix - this code should be run synchronously when loading the
  // script. Running lazily on DOMContentLoaded will yield incorrect results.
  static String _computeThisScript() native @"""
    if (!$globalState.supportsWorkers || $globalState.isWorker) return null;

    // TODO(5334778): Find a cross-platform non-brittle way of getting the
    // currently running script.
    var scripts = document.getElementsByTagName('script');
    // The scripts variable only contains the scripts that have already been
    // executed. The last one is the currently running script.
    var script = scripts[scripts.length - 1];
    var src = script && script.src;
    if (!src) {
      // TODO()
      src = "FIXME:5407062" + "_" + Math.random().toString();
      if (script) script.src = src;
    }
    _IsolateNatives._thisScriptCache = src;
    return src;
  """;

  /** Starts a new worker with the given URL. */
  static _Worker _newWorker(url) native "return new Worker(url);";

  /**
   * Spawns an isolate in a worker. [factoryName] is the Javascript constructor
   * name for the isolate entry point class.
   */
  static void _spawnWorker(factoryName, serializedReplyPort) {
    final worker = _newWorker(_thisScript);
    worker.onmessage = (e) { _processWorkerMessage(worker, e); };
    var workerId = globalState.nextWorkerId++;
    // We also store the id on the worker itself so that we can unregister it.
    worker.id = workerId;
    globalState.workers[workerId] = worker;
    worker.postMessage(_serializeMessage({
      'command': 'start',
      'id': workerId,
      'replyTo': serializedReplyPort,
      'factoryName': factoryName }));
  }

  /**
   * Assume that [e] is a browser message event and extract its message data.
   * We don't import the dom explicitly so, when workers are disabled, this
   * library can also run on top of nodejs.
   */
  static _getEventData(e) native "return e.data";

  /**
   * Process messages on a worker, either to control the worker instance or to
   * pass messages along to the isolate running in the worker.
   */
  static void _processWorkerMessage(sender, e) {
    var msg = _deserializeMessage(_getEventData(e));
    switch (msg['command']) {
      // TODO(sigmund): delete after we migrate to Isolate2
      case 'start':
        globalState.currentWorkerId = msg['id'];
        var runnerObject =
            _allocate(_getJSConstructorFromName(msg['factoryName']));
        var serializedReplyTo = msg['replyTo'];
        globalState.topEventLoop.enqueue(new IsolateContext(), function() {
          var replyTo = _deserializeMessage(serializedReplyTo);
          _startIsolate(runnerObject, replyTo);
        }, 'worker-start');
        globalState.topEventLoop.run();
        break;
      case 'start2':
        globalState.currentWorkerId = msg['id'];
        Function entryPoint = _getJSFunctionFromName(msg['functionName']);
        var replyTo = _deserializeMessage(msg['replyTo']);
        globalState.topEventLoop.enqueue(new IsolateContext(), function() {
          _startIsolate2(entryPoint, replyTo);
        }, 'worker-start');
        globalState.topEventLoop.run();
        break;
      // TODO(sigmund): delete after we migrate to Isolate2
      case 'spawn-worker':
        _spawnWorker(msg['factoryName'], msg['replyPort']);
        break;
      case 'spawn-worker2':
        _spawnWorker2(msg['functionName'], msg['uri'], msg['replyPort']);
        break;
      case 'message':
        msg['port'].send(msg['msg'], msg['replyTo']);
        globalState.topEventLoop.run();
        break;
      case 'close':
        _log("Closing Worker");
        globalState.workers.remove(sender.id);
        sender.terminate();
        globalState.topEventLoop.run();
        break;
      case 'log':
        _log(msg['msg']);
        break;
      case 'print':
        if (globalState.isWorker) {
          globalState.mainWorker.postMessage(
              _serializeMessage({'command': 'print', 'msg': msg}));
        } else {
          print(msg['msg']);
        }
        break;
      case 'error':
        throw msg['msg'];
    }
  }

  /** Log a message, forwarding to the main worker if appropriate. */
  static _log(msg) {
    if (globalState.isWorker) {
      globalState.mainWorker.postMessage(
          _serializeMessage({'command': 'log', 'msg': msg }));
    } else {
      try {
        _consoleLog(msg);
      } catch(e, trace) {
        throw new Exception(trace);
      }
    }
  }

  static void _consoleLog(msg) native "\$globalThis.console.log(msg);";


  /**
   * Extract the constructor of runnable, so it can be allocated in another
   * isolate.
   */
  static var _getJSConstructor(Isolate runnable) native """
    return runnable.constructor;
  """;

  /** Extract the constructor name of a runnable */
  // TODO(sigmund): find a browser-generic way to support this.
  static var _getJSConstructorName(Isolate runnable) native """
    return runnable.constructor.name;
  """;

  /** Find a constructor given it's name. */
  static var _getJSConstructorFromName(String factoryName) native """
    return \$globalThis[factoryName];
  """;

  static var _getJSFunctionFromName(String functionName) native """
    return \$globalThis[functionName];
  """;

  static String _getJSFunctionName(Function f) native "return f.name || null;";

  /** Create a new JavasSript object instance given it's constructor. */
  static var _allocate(var ctor) native "return new ctor();";

  /** Starts a non-worker isolate. */
  static SendPort _startNonWorker(Isolate runnable, SendPort replyTo) {
    // Spawn a new isolate and create the receive port in it.
    final spawned = new IsolateContext();

    // Instead of just running the provided runnable, we create a
    // new cloned instance of it with a fresh state in the spawned
    // isolate. This way, we do not get cross-isolate references
    // through the runnable.
    final ctor = _getJSConstructor(runnable);
    globalState.topEventLoop.enqueue(spawned, function() {
      _startIsolate(_allocate(ctor), replyTo);
    }, 'nonworker start');
  }

  /** Given a ready-to-start runnable, start running it. */
  static void _startIsolate(Isolate isolate, SendPort replyTo) {
    fillStatics(globalState.currentContext);
    ReceivePort port = new ReceivePort();
    replyTo.send(_SPAWNED_SIGNAL, port.toSendPort());
    isolate._run(port);
  }

  // TODO(sigmund): clean up above, after we make the new API the default:

  static _spawn2(String functionName, String uri, bool isLight) {
    Completer<SendPort> completer = new Completer<SendPort>();
    ReceivePort port = new ReceivePort.singleShot();
    port.receive((msg, SendPort replyPort) {
      assert(msg == _SPAWNED_SIGNAL);
      completer.complete(replyPort);
    });

    SendPort signalReply = port.toSendPort();

    if (globalState.useWorkers && !isLight) {
      _startWorker2(functionName, uri, signalReply);
    } else {
      _startNonWorker2(functionName, uri, signalReply);
    }
    return new _BufferingSendPort(
        globalState.currentContext.id, completer.future);
  }

  static SendPort _startWorker2(
      String functionName, String uri, SendPort replyPort) {
    if (globalState.isWorker) {
      globalState.mainWorker.postMessage(_serializeMessage({
          'command': 'spawn-worker2',
          'functionName': functionName,
          'uri': uri,
          'replyPort': replyPort}));
    } else {
      _spawnWorker2(functionName, uri, replyPort);
    }
  }

  static SendPort _startNonWorker2(
      String functionName, String uri, SendPort replyPort) {
    // TODO(eub): support IE9 using an iframe -- Dart issue 1702.
    if (uri != null) throw new UnsupportedOperationException(
            "Currently Isolate2.fromUri is not supported without web workers.");
    globalState.topEventLoop.enqueue(new IsolateContext(), function() {
      final func = _getJSFunctionFromName(functionName);
      _startIsolate2(func, replyPort);
    }, 'nonworker start');
  }

  static void _startIsolate2(Function topLevel, SendPort replyTo) {
    fillStatics(globalState.currentContext);
    final port = new ReceivePort();
    replyTo.send(_SPAWNED_SIGNAL, port.toSendPort());
    topLevel(port);
  }

  /**
   * Spawns an isolate in a worker. [factoryName] is the Javascript constructor
   * name for the isolate entry point class.
   */
  static void _spawnWorker2(functionName, uri, replyPort) {
    // TODO(eub): convert to 'main' once we switch back to port at top-level.
    if (functionName == null) functionName = 'isolateMain';
    if (uri == null) uri = _thisScript;
    final worker = _newWorker(uri);
    worker.onmessage = (e) { _processWorkerMessage(worker, e); };
    var workerId = globalState.nextWorkerId++;
    // We also store the id on the worker itself so that we can unregister it.
    worker.id = workerId;
    globalState.workers[workerId] = worker;
    worker.postMessage(_serializeMessage({
      'command': 'start2',
      'id': workerId,
      // Note: we serialize replyPort twice because the child worker needs to
      // first deserialize the worker id, before it can correctly deserialize
      // the port (port deserialization is sensitive to what is the current
      // workerId).
      'replyTo': _serializeMessage(replyPort),
      'functionName': functionName }));
  }
}
