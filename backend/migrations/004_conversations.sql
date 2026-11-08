CREATE TABLE public.conversations (
  id uuid PRIMARY KEY,
  client_mutation_id uuid NOT NULL UNIQUE,
  publication_id uuid NOT NULL REFERENCES public.publications(id),
  publication_author_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  participant_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (publication_author_id <> participant_id)
);
CREATE INDEX conversations_author_idx ON public.conversations(publication_author_id, participant_id, created_at, id);
CREATE INDEX conversations_participant_idx ON public.conversations(participant_id, publication_author_id, created_at, id);

CREATE TABLE public.messages (
  id uuid PRIMARY KEY,
  client_mutation_id uuid NOT NULL UNIQUE,
  conversation_id uuid NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  body text NOT NULL CHECK (char_length(btrim(body)) BETWEEN 1 AND 1000),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX messages_history_idx ON public.messages(conversation_id, created_at DESC, id DESC);

CREATE TABLE public.emergency_group_messages (
  id uuid PRIMARY KEY,
  client_mutation_id uuid NOT NULL UNIQUE,
  publication_id uuid NOT NULL REFERENCES public.publications(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  body text NOT NULL CHECK (char_length(btrim(body)) BETWEEN 1 AND 1000),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX emergency_group_history_idx ON public.emergency_group_messages(publication_id, created_at DESC, id DESC);
