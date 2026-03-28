(function () {
  "use strict";

  const state = {
    agents: [],
    sessions: [],
    selectedSessionId: null,
    selectedSession: null,
    selectedHistory: [],
    assistantPreviews: {},
    selectedLiveStatus: null,
    socket: null,
    socketOpen: false,
    socketReconnectTimer: null,
    heartbeatTimer: null,
    reconnectAttempt: 0,
    desiredChannelSessionId: null,
    activeChannel: null,
    ref: 0,
    pendingReplies: new Map()
  };

  const dom = {};

  document.addEventListener("DOMContentLoaded", function () {
    bindDom();
    bindEvents();
    setComposerDisabled(true);
    loadAgentsAndSessions().catch(function (error) {
      renderCreateError(extractErrorMessage(error));
      renderSelectedSessionStatus("Inbox unavailable");
      renderEmptyHistory("Unable to load inbox.");
    });
  });

  function bindDom() {
    dom.agentSelect = document.querySelector('[data-role="agent-select"]');
    dom.sessionList = document.querySelector('[data-role="session-list"]');
    dom.history = document.querySelector('[data-role="history"]');
    dom.composer = document.querySelector('[data-role="composer"]');
    dom.composerInput = dom.composer.querySelector('textarea[name="text"]');
    dom.composerButton = dom.composer.querySelector('button[type="submit"]');
    dom.createButton = document.querySelector('[data-role="create-session"]');
    dom.createError = document.querySelector('[data-role="create-error"]');
    dom.connectionState = document.querySelector('[data-role="connection-state"]');
    dom.sessionStatus = document.querySelector('[data-role="session-status"]');
  }

  function bindEvents() {
    dom.createButton.addEventListener("click", function () {
      createSession().catch(function (error) {
        renderCreateError(extractErrorMessage(error));
      });
    });

    dom.sessionList.addEventListener("click", function (event) {
      const button = event.target.closest("[data-session-id]");

      if (!button) {
        return;
      }

      selectSession(button.getAttribute("data-session-id")).catch(function (error) {
        if (!error || !error.handled) {
          appendSystemNote(state.selectedSessionId, extractErrorMessage(error));
        }
      });
    });

    dom.composer.addEventListener("submit", function (event) {
      event.preventDefault();

      const text = dom.composerInput.value.trim();

      if (!text || !state.selectedSessionId) {
        return;
      }

      submitMessage(state.selectedSessionId, text).catch(function (error) {
        if (!error || !error.handled) {
          appendSystemNote(state.selectedSessionId, extractErrorMessage(error));
        }
      });
    });
  }

  async function loadAgentsAndSessions(options) {
    const result = await Promise.all([fetchJson("/agents"), fetchJson("/inbox/sessions")]);
    const agentsResponse = result[0];
    const sessionsResponse = result[1];
    const previousSelection = state.selectedSessionId;

    state.agents = Array.isArray(agentsResponse.agents) ? agentsResponse.agents : [];
    state.sessions = Array.isArray(sessionsResponse.sessions) ? sessionsResponse.sessions : [];
    sortSessionsByActivity();

    renderAgentSelect();
    renderSessionList();

    const requestedSelection = options && options.selectSessionId;

    if (requestedSelection) {
      await selectSession(requestedSelection);
      return;
    }

    if (previousSelection && hasSession(previousSelection)) {
      await selectSession(previousSelection);
      return;
    }

    if (!state.selectedSessionId && state.sessions.length > 0) {
      await selectSession(state.sessions[0].session_id);
      return;
    }

    if (state.sessions.length === 0) {
      renderEmptyHistory("No sessions yet. Create one to start the inbox.");
      renderSelectedSessionStatus("No session selected");
      renderCreateError("");
      setConnectionState("");
      setComposerDisabled(true);
    }
  }

  async function createSession() {
    const payload = {};
    const selectedAgent = dom.agentSelect.value;

    renderCreateError("");

    if (selectedAgent) {
      payload.agent = selectedAgent;
    }

    const response = await fetchJson("/inbox/sessions", {
      method: "POST",
      body: JSON.stringify(payload)
    });

    await loadAgentsAndSessions({ selectSessionId: response.session_id });
  }

  async function selectSession(sessionId) {
    if (!sessionId) {
      return;
    }

    state.selectedSessionId = sessionId;
    clearSelectedSessionView(sessionId);
    renderSessionList();
    renderCreateError("");

    try {
      const result = await Promise.all([
        fetchJson("/inbox/sessions/" + encodeURIComponent(sessionId)),
        fetchJson("/inbox/sessions/" + encodeURIComponent(sessionId) + "/history")
      ]);

      const detail = result[0].session;
      const history = result[1].history;

      applySelectedSessionSnapshot(sessionId, detail, history);

      if (isTerminalStatus(detail && detail.status)) {
        state.desiredChannelSessionId = null;
        leaveActiveChannel();
        setConnectionState("");
        setComposerDisabled(true);
        return;
      }

      await attachChannel(sessionId);
    } catch (error) {
      const handledError = new Error(extractErrorMessage(error));
      handledError.handled = true;
      handleSessionSelectionError(sessionId, handledError);
      throw handledError;
    }
  }

  async function attachChannel(sessionId) {
    if (!sessionId || state.selectedSessionId !== sessionId) {
      return;
    }

    state.desiredChannelSessionId = sessionId;
    leaveActiveChannel();
    setConnectionState("connecting");
    setComposerDisabled(true);

    await ensureSocket();

    if (state.selectedSessionId !== sessionId || isTerminalStatus(state.selectedLiveStatus)) {
      return;
    }

    const topic = "session:" + sessionId;
    const joinRef = nextRef();

    state.activeChannel = {
      sessionId: sessionId,
      topic: topic,
      joinRef: joinRef,
      joined: false
    };

    sendFrame([joinRef, joinRef, topic, "phx_join", {}]);

    await awaitReply(joinRef, {
      type: "join",
      sessionId: sessionId
    });
  }

  async function submitMessage(sessionId, text) {
    if (!sessionId || sessionId !== state.selectedSessionId) {
      return;
    }

    if (isTerminalStatus(state.selectedLiveStatus)) {
      appendSystemNote(sessionId, "This session is read-only.");
      setComposerDisabled(true);
      return;
    }

    if (!state.activeChannel || !state.activeChannel.joined || state.activeChannel.sessionId !== sessionId) {
      appendSystemNote(sessionId, "Session is reconnecting. Please wait.");
      return;
    }

    const ref = nextRef();
    sendFrame([
      state.activeChannel.joinRef,
      ref,
      state.activeChannel.topic,
      "submit",
      { text: text }
    ]);

    const reply = await awaitReply(ref, {
      type: "submit",
      sessionId: sessionId
    });

    dom.composerInput.value = "";
    appendUserMessage(sessionId, reply.request_id, text);
    state.selectedLiveStatus = "running";
    updateSelectedStatus("running");
    upsertSessionRow({
      session_id: sessionId,
      status: "running",
      preview: text,
      last_event_at: Date.now()
    });
    renderSessionList();
  }

  function applyGatewayEvent(event) {
    if (!event || event.gateway_session_id !== state.selectedSessionId) {
      if (event && event.gateway_session_id) {
        updateSessionFromEvent(event);
        renderSessionList();
      }

      return;
    }

    updateSessionFromEvent(event);

    switch (event.type) {
      case "session.output.delta":
        mergeAssistantDelta(
          event.gateway_session_id,
          event.payload && event.payload.message_id,
          event.payload && event.payload.text
        );
        state.selectedLiveStatus = "running";
        updateSelectedStatus("running");
        break;

      case "session.output.completed":
        state.selectedLiveStatus = "idle";
        updateSelectedStatus("idle");
        break;

      case "session.ended":
        state.selectedLiveStatus = "stopped";
        updateSelectedStatus("stopped");
        appendSystemNote(event.gateway_session_id, "Session ended.");
        setComposerDisabled(true);
        break;

      case "session.crashed":
        state.selectedLiveStatus = "crashed";
        updateSelectedStatus("crashed");
        appendSystemNote(event.gateway_session_id, "Session crashed.");
        setComposerDisabled(true);
        break;

      default:
        break;
    }

    renderSessionList();
    renderHistory();
  }

  function renderAgentSelect() {
    dom.agentSelect.innerHTML = "";

    state.agents.forEach(function (agent) {
      const option = document.createElement("option");
      option.value = agent.agent;
      option.textContent = agent.name;

      if (agent.default) {
        option.selected = true;
      }

      dom.agentSelect.appendChild(option);
    });
  }

  function renderSessionList() {
    dom.sessionList.innerHTML = "";

    if (state.sessions.length === 0) {
      const item = document.createElement("li");
      item.className = "placeholder";
      item.textContent = "No retained sessions";
      dom.sessionList.appendChild(item);
      return;
    }

    state.sessions.forEach(function (session) {
      const item = document.createElement("li");
      const button = document.createElement("button");
      const title = document.createElement("div");
      const meta = document.createElement("div");
      const preview = document.createElement("div");
      const updated = document.createElement("div");

      button.type = "button";
      button.className = "session-row" + (session.session_id === state.selectedSessionId ? " selected" : "");
      button.setAttribute("data-session-id", session.session_id);

      title.className = "session-row-title";
      title.innerHTML =
        "<span>" +
        escapeHtml(session.agent_name || session.agent || session.session_id) +
        "</span><span>" +
        escapeHtml(session.status || "unknown") +
        "</span>";

      meta.className = "session-meta";
      meta.textContent = session.session_id;

      updated.className = "session-updated";
      updated.textContent = formatSessionTimestamp(session.last_event_at || session.created_at);

      preview.className = "session-preview";
      preview.textContent = session.preview || "No messages yet";

      button.appendChild(title);
      button.appendChild(meta);
      button.appendChild(updated);
      button.appendChild(preview);
      item.appendChild(button);
      dom.sessionList.appendChild(item);
    });
  }

  function renderHistory() {
    dom.history.innerHTML = "";

    if (!state.selectedSessionId) {
      renderEmptyHistory("Select or create a session to view history.");
      return;
    }

    if (state.selectedHistory.length === 0) {
      renderEmptyHistory("No messages yet.");
      return;
    }

    state.selectedHistory.forEach(function (entry) {
      const message = document.createElement("div");
      message.className = "message " + entry.kind;
      message.textContent = entry.text || "";
      dom.history.appendChild(message);
    });

    dom.history.scrollTop = dom.history.scrollHeight;
  }

  function renderEmptyHistory(message) {
    dom.history.innerHTML = "";

    const empty = document.createElement("div");
    empty.className = "placeholder";
    empty.textContent = message;
    dom.history.appendChild(empty);
  }

  function renderCreateError(message) {
    dom.createError.textContent = message || "";
  }

  function renderSelectedSessionStatus(status) {
    dom.sessionStatus.textContent = status || "No session selected";
  }

  function setComposerDisabled(disabled) {
    dom.composerInput.disabled = disabled;
    dom.composerButton.disabled = disabled;
  }

  function appendSystemNote(sessionId, text) {
    if (!sessionId || sessionId !== state.selectedSessionId || !text) {
      return;
    }

    state.selectedHistory.push({
      id: "system_" + Date.now(),
      kind: "system_note",
      session_id: sessionId,
      text: text
    });
    renderHistory();
  }

  function setConnectionState(stateName) {
    if (!stateName) {
      dom.connectionState.textContent = "";
      return;
    }

    if (stateName === "connecting") {
      dom.connectionState.textContent = "Connecting";
      return;
    }

    if (stateName === "disconnected") {
      dom.connectionState.textContent = "Disconnected";
      return;
    }

    dom.connectionState.textContent = stateName;
  }

  function scheduleReattach(sessionId) {
    clearTimeout(state.socketReconnectTimer);

    if (!sessionId || sessionId !== state.selectedSessionId || isTerminalStatus(state.selectedLiveStatus)) {
      return;
    }

    const delay = Math.min(4000, 500 * Math.max(state.reconnectAttempt, 1));

    state.socketReconnectTimer = window.setTimeout(function () {
      attachChannel(sessionId).catch(function () {
        scheduleReattach(sessionId);
      });
    }, delay);
  }

  function ensureSocket() {
    if (state.socket && state.socketOpen) {
      return Promise.resolve();
    }

    if (state.socket && state.socket.readyState === WebSocket.CONNECTING) {
      return waitForSocketOpen();
    }

    return connectSocket();
  }

  function connectSocket() {
    state.reconnectAttempt += 1;
    setConnectionState("connecting");

    const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    const socket = new WebSocket(protocol + "//" + window.location.host + "/socket/websocket?vsn=2.0.0");

    state.socket = socket;

    socket.addEventListener("open", function () {
      handleSocketOpen(socket);
    });
    socket.addEventListener("close", function () {
      handleSocketClose(socket);
    });
    socket.addEventListener("error", function () {
      handleSocketClose(socket);
    });
    socket.addEventListener("message", function (event) {
      handleSocketMessage(socket, event);
    });

    return waitForSocketOpen();
  }

  function waitForSocketOpen() {
    return new Promise(function (resolve, reject) {
      if (state.socket && state.socketOpen) {
        resolve();
        return;
      }

      const startedAt = Date.now();
      const timer = window.setInterval(function () {
        if (state.socket && state.socketOpen) {
          window.clearInterval(timer);
          resolve();
          return;
        }

        if (Date.now() - startedAt > 5000) {
          window.clearInterval(timer);
          reject(new Error("Socket connection timed out"));
        }
      }, 50);
    });
  }

  function handleSocketOpen(socket) {
    if (socket !== state.socket) {
      return;
    }

    state.socketOpen = true;
    state.reconnectAttempt = 0;
    startHeartbeat();
  }

  function handleSocketClose(socket) {
    if (socket !== state.socket) {
      return;
    }

    const hadDesiredSession = state.desiredChannelSessionId;

    state.socketOpen = false;
    stopHeartbeat();
    rejectPendingReplies("Socket disconnected");

    if (state.activeChannel) {
      state.activeChannel.joined = false;
    }

    if (hadDesiredSession && hadDesiredSession === state.selectedSessionId && !isTerminalStatus(state.selectedLiveStatus)) {
      setConnectionState("disconnected");
      setComposerDisabled(true);
      scheduleReattach(hadDesiredSession);
    }
  }

  function handleSocketMessage(socket, event) {
    if (socket !== state.socket) {
      return;
    }

    let payload;

    try {
      payload = JSON.parse(event.data);
    } catch (_error) {
      return;
    }

    if (!Array.isArray(payload) || payload.length < 5) {
      return;
    }

    const joinRef = payload[0];
    const ref = payload[1];
    const topic = payload[2];
    const eventName = payload[3];
    const body = payload[4] || {};

    if (eventName === "phx_reply") {
      handleReply(ref, topic, body);
      return;
    }

    if (eventName === "phx_error" || eventName === "phx_close") {
      if (
        state.activeChannel &&
        topic === state.activeChannel.topic &&
        joinRef === state.activeChannel.joinRef
      ) {
        state.activeChannel.joined = false;
        setConnectionState("disconnected");
        setComposerDisabled(true);
        scheduleReattach(state.activeChannel.sessionId);
      }

      return;
    }

    if (eventName === "event") {
      applyGatewayEvent(body);
    }
  }

  function handleReply(ref, topic, body) {
    const pending = state.pendingReplies.get(ref);

    if (!pending) {
      return;
    }

    state.pendingReplies.delete(ref);

    if (body.status === "ok") {
      if (pending.type === "join" && state.activeChannel && state.activeChannel.topic === topic) {
        state.activeChannel.joined = true;
        state.selectedLiveStatus = body.response && body.response.status ? body.response.status : state.selectedLiveStatus;
        updateSelectedStatus(state.selectedLiveStatus);
        setConnectionState("");
        setComposerDisabled(false);
      }

      pending.resolve(body.response || {});
      return;
    }

    const reason = body.response && body.response.reason ? body.response.reason : "Request failed";

    if (pending.type === "join") {
      handleJoinError(pending.sessionId, body.response || {});
    } else if (pending.type === "submit") {
      handleSubmitError(pending.sessionId, body.response || {});
    }

    const error = new Error(reason);
    error.handled = true;
    pending.reject(error);
  }

  function handleJoinError(sessionId, response) {
    if (sessionId !== state.selectedSessionId) {
      return;
    }

    state.desiredChannelSessionId = null;
    leaveActiveChannel();
    setComposerDisabled(true);

    if (response.reason === "session_read_only") {
      appendSystemNote(sessionId, "Session is read-only.");
      resolveJoinFailureFromHttp(sessionId, response);
      return;
    }

    appendSystemNote(sessionId, "Live connection unavailable. History is read-only.");
    resolveJoinFailureFromHttp(sessionId, response);
  }

  function handleSubmitError(sessionId, response) {
    if (sessionId !== state.selectedSessionId) {
      return;
    }

    appendSystemNote(sessionId, friendlySubmitErrorMessage(response));
    setComposerDisabled(true);
    state.desiredChannelSessionId = null;
    resolveJoinFailureFromHttp(sessionId, response);
  }

  function startHeartbeat() {
    stopHeartbeat();

    state.heartbeatTimer = window.setInterval(function () {
      if (!state.socketOpen) {
        return;
      }

      const ref = nextRef();
      sendFrame([null, ref, "phoenix", "heartbeat", {}]);
    }, 30000);
  }

  function stopHeartbeat() {
    clearInterval(state.heartbeatTimer);
    state.heartbeatTimer = null;
  }

  function sendFrame(frame) {
    if (!state.socket || state.socket.readyState !== WebSocket.OPEN) {
      throw new Error("Socket is not open");
    }

    state.socket.send(JSON.stringify(frame));
  }

  function awaitReply(ref, meta) {
    return new Promise(function (resolve, reject) {
      state.pendingReplies.set(ref, {
        type: meta.type,
        sessionId: meta.sessionId,
        resolve: resolve,
        reject: reject
      });
    });
  }

  function rejectPendingReplies(message) {
    state.pendingReplies.forEach(function (pending) {
      pending.reject(new Error(message));
    });
    state.pendingReplies.clear();
  }

  function leaveActiveChannel() {
    if (!state.activeChannel) {
      return;
    }

    if (state.socket && state.socket.readyState === WebSocket.OPEN) {
      try {
        const ref = nextRef();
        sendFrame([state.activeChannel.joinRef, ref, state.activeChannel.topic, "phx_leave", {}]);
      } catch (_error) {
        // Ignore best-effort leave failures while switching sessions.
      }
    }

    state.activeChannel = null;
  }

  function fetchSelectedSessionOverHttp(sessionId) {
    return Promise.all([
      fetchJson("/inbox/sessions/" + encodeURIComponent(sessionId)),
      fetchJson("/inbox/sessions/" + encodeURIComponent(sessionId) + "/history")
    ]).then(function (result) {
      return {
        detail: result[0].session,
        history: result[1].history
      };
    });
  }

  function updateSessionFromEvent(event) {
    if (!event || !event.gateway_session_id) {
      return;
    }

    const patch = {
      session_id: event.gateway_session_id
    };

    if (event.type === "session.output.delta") {
      const messageId = event.payload && event.payload.message_id;
      patch.status = "running";
      patch.preview = updateAssistantPreview(
        event.gateway_session_id,
        messageId,
        event.payload && event.payload.text
      );
      patch.last_event_at = Date.now();
    }

    if (event.type === "session.output.completed") {
      patch.status = "idle";
      patch.last_event_at = Date.now();
    }

    if (event.type === "session.ended") {
      patch.status = "stopped";
      patch.last_event_at = Date.now();
    }

    if (event.type === "session.crashed") {
      patch.status = "crashed";
      patch.last_event_at = Date.now();
    }

    upsertSessionRow(patch);
  }

  function mergeAssistantDelta(sessionId, messageId, text) {
    if (!sessionId || sessionId !== state.selectedSessionId) {
      return;
    }

    const existing = state.selectedHistory.find(function (entry) {
      return entry.kind === "assistant_message" && entry.message_id === messageId;
    });

    if (existing) {
      existing.text = existing.text + (text || "");
    } else {
      state.selectedHistory.push({
        id: "assistant_" + Date.now(),
        kind: "assistant_message",
        message_id: messageId,
        text: text || ""
      });
    }

    updateAssistantPreview(sessionId, messageId, text);
  }

  function appendUserMessage(sessionId, requestId, text) {
    if (sessionId !== state.selectedSessionId) {
      return;
    }

    state.selectedHistory.push({
      id: "user_" + requestId,
      kind: "user_message",
      message_id: requestId,
      text: text
    });
    renderHistory();
  }

  function upsertSessionRow(sessionPatch) {
    if (!sessionPatch || !sessionPatch.session_id) {
      return;
    }

    const index = state.sessions.findIndex(function (session) {
      return session.session_id === sessionPatch.session_id;
    });

    if (index === -1) {
      state.sessions.unshift(sessionPatch);
      sortSessionsByActivity();
      return;
    }

    state.sessions[index] = Object.assign({}, state.sessions[index], sessionPatch);
    sortSessionsByActivity();
  }

  function sortSessionsByActivity() {
    state.sessions.sort(function (left, right) {
      const leftActivity = left.last_event_at || left.created_at || 0;
      const rightActivity = right.last_event_at || right.created_at || 0;
      const leftCreatedAt = left.created_at || 0;
      const rightCreatedAt = right.created_at || 0;

      if (rightActivity !== leftActivity) {
        return rightActivity - leftActivity;
      }

      if (rightCreatedAt !== leftCreatedAt) {
        return rightCreatedAt - leftCreatedAt;
      }

      return String(left.session_id || "").localeCompare(String(right.session_id || ""));
    });
  }

  function updateSelectedStatus(status) {
    if (!state.selectedSession) {
      state.selectedSession = { session_id: state.selectedSessionId };
    }

    state.selectedSession.status = status;
    state.selectedLiveStatus = status;
    upsertSessionRow({
      session_id: state.selectedSessionId,
      status: status,
      last_event_at: Date.now()
    });
    renderSelectedSessionStatus(formatSessionStatus(state.selectedSession));
  }

  function formatSessionStatus(session) {
    if (!session) {
      return "No session selected";
    }

    const agent = session.agent_name || session.agent || "unknown agent";
    const status = session.status || "unknown";
    return agent + " · " + status + " · " + session.session_id;
  }

  function hasSession(sessionId) {
    return state.sessions.some(function (session) {
      return session.session_id === sessionId;
    });
  }

  function resolveJoinFailureFromHttp(sessionId, response) {
    setConnectionState("");

    return fetchSelectedSessionOverHttp(sessionId)
      .then(function (snapshot) {
        if (state.selectedSessionId !== sessionId) {
          return;
        }

        applySelectedSessionSnapshot(sessionId, snapshot.detail, snapshot.history);

        if (response && response.status && !snapshot.detail.status) {
          state.selectedLiveStatus = response.status;
        }

        setComposerDisabled(true);
      })
      .catch(function (_error) {
        if (state.selectedSessionId !== sessionId) {
          return;
        }

        if (response && response.status) {
          updateSelectedStatus(response.status);
        }

        setConnectionState("");
        setComposerDisabled(true);
      });
  }

  function applySelectedSessionSnapshot(sessionId, detail, history) {
    if (state.selectedSessionId !== sessionId) {
      return;
    }

    const systemNotes = state.selectedHistory.filter(function (entry) {
      return entry.kind === "system_note" && entry.session_id === sessionId;
    });
    const sessionHistory = Array.isArray(history) ? history.slice() : [];

    state.selectedSession = detail;
    state.selectedHistory = sessionHistory.concat(systemNotes);
    state.selectedLiveStatus = detail && detail.status;
    hydrateAssistantPreview(sessionId, sessionHistory, detail);

    upsertSessionRow(detail);
    renderSessionList();
    renderHistory();
    renderSelectedSessionStatus(formatSessionStatus(detail));
  }

  function clearSelectedSessionView(sessionId) {
    state.selectedSession = { session_id: sessionId };
    state.selectedHistory = [];
    state.selectedLiveStatus = null;
    renderSelectedSessionStatus("Loading session " + sessionId + "...");
    renderEmptyHistory("Loading session history...");
    setComposerDisabled(true);
  }

  function handleSessionSelectionError(sessionId, error) {
    if (sessionId !== state.selectedSessionId) {
      return;
    }

    state.selectedSession = { session_id: sessionId };
    state.selectedHistory = [];
    renderSelectedSessionStatus("Unable to load session " + sessionId);
    renderEmptyHistory(extractErrorMessage(error));
    setComposerDisabled(true);
  }

  function hydrateAssistantPreview(sessionId, history, detail) {
    const previews = {};
    let latestPreview = detail && detail.preview ? detail.preview : null;

    history.forEach(function (entry) {
      if (entry.kind !== "assistant_message") {
        return;
      }

      if (entry.message_id) {
        previews[entry.message_id] = entry.text || "";
      }

      latestPreview = entry.text || latestPreview;
    });

    state.assistantPreviews[sessionId] = previews;

    if (latestPreview) {
      upsertSessionRow({
        session_id: sessionId,
        preview: latestPreview
      });
    }
  }

  function updateAssistantPreview(sessionId, messageId, text) {
    if (!state.assistantPreviews[sessionId]) {
      state.assistantPreviews[sessionId] = {};
    }

    if (!messageId) {
      return text || null;
    }

    const mergedText = (state.assistantPreviews[sessionId][messageId] || "") + (text || "");
    state.assistantPreviews[sessionId][messageId] = mergedText;
    return mergedText;
  }

  function formatSessionTimestamp(timestamp) {
    if (!timestamp) {
      return "Updated unknown";
    }

    const date = new Date(timestamp);

    if (Number.isNaN(date.getTime())) {
      return "Updated unknown";
    }

    const deltaMs = Date.now() - date.getTime();

    if (deltaMs < 60 * 1000) {
      return "Updated just now";
    }

    if (deltaMs < 60 * 60 * 1000) {
      return "Updated " + Math.floor(deltaMs / (60 * 1000)) + "m ago";
    }

    if (deltaMs < 24 * 60 * 60 * 1000) {
      return "Updated " + Math.floor(deltaMs / (60 * 60 * 1000)) + "h ago";
    }

    return "Updated " + date.toLocaleString();
  }

  function isTerminalStatus(status) {
    return status === "stopped" || status === "crashed";
  }

  function friendlySubmitErrorMessage(response) {
    const reason = response && response.reason;

    if (reason === "session_read_only") {
      return "Session is read-only.";
    }

    if (reason === "session_unavailable") {
      return "Live connection unavailable. History is read-only.";
    }

    if (reason === "missing_text_field") {
      return "Message text is required.";
    }

    return "Message submit failed.";
  }

  function nextRef() {
    state.ref += 1;
    return String(state.ref);
  }

  function fetchJson(url, options) {
    const requestOptions = Object.assign(
      {
        headers: {
          Accept: "application/json"
        }
      },
      options || {}
    );

    if (requestOptions.body) {
      requestOptions.headers["Content-Type"] = "application/json";
    }

    return window.fetch(url, requestOptions).then(function (response) {
      return response.text().then(function (text) {
        const data = text ? JSON.parse(text) : {};

        if (!response.ok) {
          throw buildHttpError(data, response.status);
        }

        return data;
      });
    });
  }

  function buildHttpError(data, status) {
    const message =
      data &&
      data.error &&
      (data.error.message || data.error.reason || data.error.type || ("HTTP " + status));

    const error = new Error(message || ("HTTP " + status));
    error.status = status;
    error.payload = data;
    return error;
  }

  function extractErrorMessage(error) {
    if (!error) {
      return "Unknown error";
    }

    if (error.payload && error.payload.error && error.payload.error.message) {
      return error.payload.error.message;
    }

    return error.message || String(error);
  }

  function escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/\"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }
})();
