defmodule PrehenWeb.InboxPage do
  @moduledoc false

  def render do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Prehen Inbox</title>
        <link rel="stylesheet" href="/inbox.css" />
      </head>
      <body>
        <div class="inbox-shell">
          <aside class="sidebar">
            <div class="sidebar-card">
              <h1>Prehen Inbox</h1>
              <p class="muted">Single-node gateway inbox</p>
            </div>

            <div class="sidebar-card controls">
              <label class="field-label" for="agent-select">Agent</label>
              <select id="agent-select" data-role="agent-select"></select>
              <button type="button" data-role="create-session">Create Session</button>
              <div class="create-error" data-role="create-error" aria-live="polite"></div>
            </div>

            <div class="sidebar-card sessions-card">
              <div class="section-heading">
                <h2>Sessions</h2>
                <span class="connection-state" data-role="connection-state"></span>
              </div>
              <ul class="session-list" data-role="session-list"></ul>
            </div>
          </aside>

          <main class="detail">
            <header class="detail-header">
              <div>
                <h2>Conversation</h2>
                <p class="detail-subtitle" data-role="session-status">No session selected</p>
              </div>
            </header>

            <section class="history" data-role="history" aria-live="polite"></section>

            <form class="composer" data-role="composer">
              <label class="field-label" for="composer-input">Message</label>
              <textarea
                id="composer-input"
                name="text"
                rows="4"
                placeholder="Select or create a live session to send a message"
              ></textarea>
              <div class="composer-actions">
                <button type="submit">Send</button>
              </div>
            </form>
          </main>
        </div>

        <script src="/inbox.js"></script>
      </body>
    </html>
    """
  end
end
