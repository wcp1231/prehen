export const API_BASE = "/api";

export async function createSession(agent?: string): Promise<{ session_id: string }> {
  const body = agent ? { agent } : {};
  const res = await fetch(`${API_BASE}/sessions`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`Failed to create session: ${res.status}`);
  return res.json();
}

export async function listSessions(): Promise<{
  sessions: Array<{ session_id: string; status: string; inserted_at_ms: number }>;
}> {
  const res = await fetch(`${API_BASE}/sessions`);
  if (!res.ok) throw new Error(`Failed to list sessions: ${res.status}`);
  return res.json();
}

export async function getSessionStatus(
  sessionId: string
): Promise<{ session: Record<string, unknown> }> {
  const res = await fetch(`${API_BASE}/sessions/${sessionId}`);
  if (!res.ok) throw new Error(`Failed to get session: ${res.status}`);
  return res.json();
}

export async function deleteSession(sessionId: string): Promise<void> {
  const res = await fetch(`${API_BASE}/sessions/${sessionId}`, {
    method: "DELETE",
  });
  if (!res.ok) throw new Error(`Failed to delete session: ${res.status}`);
}

export async function replaySession(
  sessionId: string
): Promise<{ events: Array<Record<string, unknown>> }> {
  const res = await fetch(`${API_BASE}/sessions/${sessionId}/replay`);
  if (!res.ok) throw new Error(`Failed to replay session: ${res.status}`);
  return res.json();
}

export async function listAgents(): Promise<{
  agents: Array<{ agent: string; name: string; description?: string }>;
}> {
  const res = await fetch(`${API_BASE}/agents`);
  if (!res.ok) throw new Error(`Failed to list agents: ${res.status}`);
  return res.json();
}
