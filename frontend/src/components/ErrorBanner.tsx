import { useState } from "react";

interface ErrorBannerProps {
  code: string;
  message: string;
  details?: unknown;
}

export default function ErrorBanner({ code, message, details }: ErrorBannerProps) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div className="error-banner">
      <div className="error-banner-header">
        <span className="error-banner-code">{code}</span>
        <span className="error-banner-message">{message}</span>
      </div>

      {details != null && (
        <div className="error-banner-details">
          <button
            className="error-banner-toggle"
            onClick={() => setExpanded(!expanded)}
          >
            {expanded ? "Hide details" : "Show details"}
          </button>
          {expanded && (
            <pre className="error-banner-json">
              {JSON.stringify(details, null, 2)}
            </pre>
          )}
        </div>
      )}
    </div>
  );
}
