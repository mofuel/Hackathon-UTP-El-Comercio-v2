CREATE TABLE public.private_message_installations (
  device_id uuid PRIMARY KEY,
  installation_id text NOT NULL UNIQUE CHECK (char_length(installation_id) BETWEEN 10 AND 256),
  recipient_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX private_message_installations_recipient_idx ON public.private_message_installations(recipient_id);

CREATE TABLE public.private_message_push_queue (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  device_id uuid NOT NULL REFERENCES public.private_message_installations(device_id) ON DELETE CASCADE,
  message_id uuid NOT NULL REFERENCES public.messages(id) ON DELETE CASCADE,
  installation_id text NOT NULL,
  recipient_id uuid NOT NULL,
  attempts integer NOT NULL DEFAULT 0,
  available_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (device_id, message_id)
);
CREATE INDEX private_message_push_ready_idx ON public.private_message_push_queue(available_at, id);

CREATE FUNCTION public.enqueue_private_message_push()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  INSERT INTO public.private_message_push_queue(device_id, message_id, installation_id, recipient_id)
  SELECT i.device_id, NEW.id, i.installation_id, i.recipient_id
  FROM public.conversations c
  JOIN public.private_message_installations i ON i.recipient_id = CASE
    WHEN c.publication_author_id = NEW.sender_id THEN c.participant_id
    WHEN c.participant_id = NEW.sender_id THEN c.publication_author_id
  END
  WHERE c.id = NEW.conversation_id
  ON CONFLICT (device_id, message_id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER enqueue_private_message_push AFTER INSERT ON public.messages
FOR EACH ROW EXECUTE FUNCTION public.enqueue_private_message_push();
