class ConnectionManager {
    static version = [1,0,0];

    static BLINK_ALWAYS = 0;
    static BLINK_NEVER = 1;
    static BLINK_ON_CONNECT = 2;
    static BLINK_ON_DISCONNECT = 3;

    // Settings
    _checkTimeout = null;
    _stayConnected = null;
    _blinkupBehavior = null;

    // Global Handlers
    _onConnect = null;
    _onDisconnect = null;

    // Connection State
    _connected = null;
    _connecting = null;

    // The onConnected task queue and logs
    _queue = null;
    _logs = null;

    constructor(settings = {}) {
        // Grab settings
        _checkTimeout = ("checkTimeout" in settings) ? settings.checkTimeout : 5;
        _stayConnected = ("stayConnected" in settings) ? settings.stayConnected : false;
        _blinkupBehavior = ("blinkupBehavior" in settings) ? settings.blinkupBehavior : BLINK_ON_DISCONNECT;

        // Initialize the onConnected task queue and logs
        _queue = [];
        _logs = [];

        // Set the timeout policy + disconnect if required
        server.setsendtimeoutpolicy(RETURN_ON_ERROR, WAIT_TIL_SENT, 0);
        imp.setsendbuffersize(8096);

        // Disconnect if required
        if ("startDisconnected" in settings && settings.startDisconnected) {
            server.disconnect();
        }

        // Get the initial state and set BlinkUp accordingly
        _connected = server.isconnected();
        _setBlinkUpState();

        // Start the watchdog
        _watchdog();
    }

    // Sets an onConnect handler that fires everytime we connect. Passing
    // null to this function removes the onConnect handler
    //
    // Parameters:
    //      callback:   The onConnect handler (no parameters)
    //
    // Returns:         this
    function onConnect(callback) {
        _onConnect = callback;

        return this;
    }

    // Sets a onDisconnect handler that fires everytime we disconnect. Passing
    // null to this function removes the onDisconnect handler
    //
    // Parameters:
    //      callback:   The onDisconnectHandler with 1 parameter:
    //        expected    True - when onDisconnect was called because of a disconnect()
    //                    False - otherwise
    //
    // Returns:         this
    function onDisconnect(callback) {
        _onDisconnect = callback;

        return this;
    }

    // Returns the ConnectionManager's view of if we're connected or not
    function isConnected() {
        return _connected;
    }

    // Attempts to connect. If the server is already connected, or the
    // connection attempt was successful, run the onConnect handler, and
    // any other onConnected tasks
    function connect() {
        // If we're connecting/disconnecting, try again in 0.5 seconds
        if (_connecting) return false;

        // If we're already connected: invoke the onConnectedFlow and return
        if (_connected) {
            _onConnectedFlow();
            return true;;
        }

        // Otherwise, try to connect...

        // Set the _connecting flag at the start
        _connecting = true;
        server.connect(function(result) {
            // clear connecting falg when we're done trying to connect
            _connecting = false;
            if (result == SERVER_CONNECTED) {
                // If it worked, run the onConnectedFlow
                _connected = true;
                _onConnectedFlow();
            } else {
                // Otherwise, do nothing.. _watchdog will pick it up if required
            }
        }.bindenv(this));

        return true;
    }

    // Disconnects, and runs the onDisconnected handler
    function disconnect() {
        // If we're connecting / disconnecting, try again in 0.5 seconds
        if (_connecting) { return false };

        // if we're already disconnected: invoke the onDisconnectedFlow and return
        if (!_connected) {
            _onDisconnectedFlow(true);
            return true;
        }

        // Disconnect
        server.flush(30);
        server.disconnect();
        // Set the flag
        _connected = false;
        _connecting = false;

        // Run the onDisconnectedFlow
        _onDisconnectedFlow(true);

        return true;
    }

    // Pushes a task onto the onConnected task queue that will
    // be executed the next time the device connects. if the device
    // is already connected, it will be executed immediatly
    //
    // Parameters:
    //      callback    The task to execute
    //
    // Returns:         this
    function onNextConnect(callback) {
        _queue.push(callback);
        _processQueue();
        return this;
    }

    // Queues the callback to run on next connect, then connects,
    // runs all queued tasks and disconnects
    function connectFor(callback) {
        local cb = _connectForCallbackFactory(callback);
        _queue.push(cb);
        connect();
    }

    // Sets the BlinkUp behaviour to one of the preconfigured options
    //
    // Parameters:
    //      state:      BLINK_ALWAYS | BLINK_NEVER | BLINK_ON_CONNECTED | BLINK_ON_DISCONNECTED
    //
    // Returns:         this
    function setBlinkUpBehaviour(state) {
        _blinkupBehavior = state;
        _setBlinkUpState();

        return this;
    }

    function log(obj, error = false) {
        if (_connected) {
            server.log(obj.tostring());
        } else {
            _logs.push({ "ts": time(), "error": 0, "log": obj.tostring() });
        }
    }

    function error(obj) {
        log(obj, true);
    }

    //-------------------- PRIVATE METHODS --------------------//

    // Wraps a callback function so it executes, then immediatly
    // disconnects.
    function _connectForCallbackFactory(callback) {
        local __cm = this;
        return function() {
            callback();
            __cm.disconnect();
        };
    }

    // Watches for changes in connection state, and invokes the
    // onConnectedFlow and onDisconnectedFlow where appropriate
    function _watchdog() {
        // Schedule _watchdog to run again
        imp.wakeup(_checkTimeout, _watchdog.bindenv(this));

        // Don't asddo anything if we're connecting
        if (_connecting) return;

        // Check if we're connected
        local connected = server.isconnected()

        // If the state hasn't changed, we're done
        if (_connected == connected) return;

        // Set the new connected state
        _connected = connected;

        // Run the appropriate flow
        if (connected) {
            _onConnectedFlow();
        } else {
            _onDisconnectedFlow(false);
        }
    }

    // Runs whenever we connect or call connect()
    function _onConnectedFlow() {
        local __cm = this;

        // Set the BlinkUp State
        _setBlinkUpState();

        while(_logs.len() > 0) {
            local log = _logs.remove(0);
            if (!log.error) {
                server.log(log.ts + " - " + log.log)
            } else {
                server.error(log.ts + " - " + log.log)
            }
        }

        // Run the global onConnected Handler if it exists
        if (_onConnect != null) {
            imp.wakeup(0, function() { __cm._onConnect(); });
        }

        _processQueue();
    }

    // Helper function for _onConnectedFlow that processes all the tasks
    // in the onConnected _queue or quits once we're no longer connected
    function _processQueue() {
        // If we're done, are connecting/disconnecting, or are disconnected
        if (_queue.len() == 0 || _connecting || !_connected) return;

        local __cm = this;
        local cb = __cm._queue.remove(0);
        imp.wakeup(0, function() {
            // Invoke the next queued task
            cb();
            // Do it again!!
            __cm._processQueue();
        });
    }

    // Runs whenever we disconnect, or call disconnect()
    function _onDisconnectedFlow(expected) {
        local __cm = this;

        // Set the BlinkUp State
        _setBlinkUpState();

        // Run the global onDisconnected Handler if it exists
        if (_onDisconnect != null) {
            imp.wakeup(0, function() { __cm._onDisconnect(expected); });
        }

        if (_stayConnected) {
            imp.wakeup(0, function() { __cm.connect(); });
        }
    }

    // Enables of disables BlinkUp based on _blinkupBehavior and _connected
    function _setBlinkUpState() {
        // If it's set to always blinkup
        if (_blinkupBehavior == BLINK_ALWAYS) {
            imp.enableblinkup(true);
            return;
        }
        // If it's set to never blinkup
        if (_blinkupBehavior == BLINK_NEVER) {
            imp.enableblinkup(false);
            return;
        }

        // If it's set to blinkup on a specific state
        if ((_connected && _blinkupBehavior == BLINK_ON_CONNECT)
        || (!_connected && _blinkupBehavior == BLINK_ON_DISCONNECT)) {
            imp.enableblinkup(true);
        } else {
            imp.enableblinkup(false);
        }
    }
}
