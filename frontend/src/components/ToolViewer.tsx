import type { ToolCall } from "../stores/sessionStore";

interface ToolViewerProps {
  toolCall: ToolCall;
}

export default function ToolViewer({ toolCall }: ToolViewerProps) {
  const statusIcon =
    toolCall.status === "running"
      ? "⟳"
      : toolCall.status === "completed"
        ? "✓"
        : "✗";

  const statusClass = `tool-status tool-status--${toolCall.status}`;

  return (
    <div className="tool-card">
      <div className="tool-header">
        <span className={statusClass}>{statusIcon}</span>
        <span className="tool-name">{toolCall.name}</span>
      </div>
      {Object.keys(toolCall.arguments).length > 0 && (
        <details className="tool-details">
          <summary>Arguments</summary>
          <pre className="tool-json">
            {JSON.stringify(toolCall.arguments, null, 2)}
          </pre>
        </details>
      )}
      {toolCall.result !== undefined && (
        <details className="tool-details">
          <summary>Result</summary>
          <pre className="tool-json">
            {typeof toolCall.result === "string"
              ? toolCall.result
              : JSON.stringify(toolCall.result, null, 2)}
          </pre>
        </details>
      )}
    </div>
  );
}
