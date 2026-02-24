import { useEffect, useState, useCallback } from "react";
import { listSessions, createSession, deleteSession, listAgents } from "../lib/api";

interface Session {
  session_id: string;
  status: string;
  inserted_at_ms: number;
}

interface Agent {
  agent: string;
  name: string;
  description?: string;
}

interface SessionListProps {
  onSelectSession: (sessionId: string) => void;
}

export default function SessionList({ onSelectSession }: SessionListProps) {
  const [sessions, setSessions] = useState<Session[]>([]);
  const [agents, setAgents] = useState<Agent[]>([]);
  const [loading, setLoading] = useState(true);
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchData = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [sessionRes, agentRes] = await Promise.all([
        listSessions(),
        listAgents(),
      ]);
      setSessions(sessionRes.sessions);
      setAgents(agentRes.agents);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  const handleCreate = async (agent?: string) => {
    setCreating(true);
    setError(null);
    try {
      const res = await createSession(agent);
      onSelectSession(res.session_id);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setCreating(false);
    }
  };

  const handleDelete = async (sessionId: string) => {
    try {
      await deleteSession(sessionId);
      setSessions((prev) => prev.filter((s) => s.session_id !== sessionId));
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  };

  if (loading) {
    return <div className="session-list-loading">Loading...</div>;
  }

  return (
    <div className="session-list">
      <h1 className="session-list-title">Prehen</h1>

      {error && <div className="session-list-error">{error}</div>}

      <div className="session-list-create">
        <h2>New Session</h2>
        {agents.length > 0 ? (
          <div className="agent-grid">
            {agents.map((agent) => (
              <button
                key={agent.agent}
                className="agent-card"
                onClick={() => handleCreate(agent.agent)}
                disabled={creating}
              >
                <span className="agent-card-name">{agent.name}</span>
                {agent.description && (
                  <span className="agent-card-desc">{agent.description}</span>
                )}
              </button>
            ))}
          </div>
        ) : (
          <button
            className="btn btn-primary"
            onClick={() => handleCreate()}
            disabled={creating}
          >
            {creating ? "Creating..." : "Create Session"}
          </button>
        )}
      </div>

      {sessions.length > 0 && (
        <div className="session-list-existing">
          <h2>Existing Sessions</h2>
          <div className="session-grid">
            {sessions.map((session) => (
              <div key={session.session_id} className="session-card">
                <button
                  className="session-card-main"
                  onClick={() => onSelectSession(session.session_id)}
                >
                  <span className="session-card-id">
                    {session.session_id.slice(0, 8)}...
                  </span>
                  <span className={`session-card-status session-card-status--${session.status}`}>
                    {session.status}
                  </span>
                </button>
                <button
                  className="session-card-delete"
                  onClick={() => handleDelete(session.session_id)}
                  title="Delete session"
                >
                  ×
                </button>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
