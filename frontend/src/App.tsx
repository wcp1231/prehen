import { BrowserRouter, Routes, Route, useNavigate, useParams } from "react-router";
import SessionList from "./components/SessionList";
import SessionPage from "./components/SessionPage";
import { useSessionStore } from "./stores/sessionStore";

function SessionListPage() {
  const navigate = useNavigate();
  return (
    <SessionList
      onSelectSession={(id) => navigate(`/session/${id}`)}
    />
  );
}

function SessionDetailPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const reset = useSessionStore((s) => s.reset);

  const handleBack = () => {
    reset();
    navigate("/");
  };

  if (!id) return null;

  return <SessionPage sessionId={id} onBack={handleBack} />;
}

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<SessionListPage />} />
        <Route path="/sessions" element={<SessionListPage />} />
        <Route path="/session/:id" element={<SessionDetailPage />} />
      </Routes>
    </BrowserRouter>
  );
}
