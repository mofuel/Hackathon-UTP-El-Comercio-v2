CREATE TABLE public.publication_operation_receipts (
  actor_key text NOT NULL,
  operation_id text NOT NULL CHECK (char_length(operation_id) BETWEEN 1 AND 100),
  request_hash bytea NOT NULL,
  result_version integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (actor_key, operation_id)
);

CREATE TABLE public.recommendations (
  id uuid PRIMARY KEY,
  client_mutation_id uuid NOT NULL UNIQUE,
  publication_id uuid NOT NULL REFERENCES public.publications(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  comment text NOT NULL DEFAULT '' CHECK (char_length(comment) <= 400),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (publication_id, user_id)
);
CREATE INDEX recommendations_user_idx ON public.recommendations(user_id);

CREATE TABLE public.help_offers (
  id uuid PRIMARY KEY,
  client_mutation_id uuid NOT NULL UNIQUE,
  publication_id uuid NOT NULL REFERENCES public.publications(id) ON DELETE CASCADE,
  helper_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  note text NOT NULL DEFAULT '' CHECK (char_length(note) <= 500),
  resource_shared text NOT NULL DEFAULT '' CHECK (char_length(resource_shared) <= 200),
  explicit_share_consent boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'enviada' CHECK (status IN ('enviada','aceptada','retirada','completada')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (publication_id, helper_id),
  CHECK (btrim(resource_shared) = '' OR explicit_share_consent)
);
CREATE INDEX help_offers_helper_idx ON public.help_offers(helper_id);

CREATE TABLE public.guest_report_limits (
  source_hash text PRIMARY KEY,
  window_start timestamptz NOT NULL,
  reports integer NOT NULL CHECK (reports > 0)
);

CREATE TABLE public.community_resources (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL CHECK (kind IN ('punto_encuentro','recurso_comunitario','grupo_apoyo','directorio_oficial')),
  title text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 3 AND 140),
  description text NOT NULL CHECK (char_length(description) <= 1000),
  neighborhood text NOT NULL DEFAULT 'Pueblo Libre',
  sector text NOT NULL DEFAULT 'Sector Plaza Bolívar',
  approx_lat double precision NOT NULL CHECK (approx_lat BETWEEN -90 AND 90 AND approx_lat=public.round_public_coord(approx_lat)),
  approx_lng double precision NOT NULL CHECK (approx_lng BETWEEN -180 AND 180 AND approx_lng=public.round_public_coord(approx_lng)),
  location public.geography(Point, 4326) GENERATED ALWAYS AS (
    public.st_setsrid(public.st_makepoint(approx_lng, approx_lat), 4326)::public.geography
  ) STORED,
  contact_info text NOT NULL DEFAULT '',
  source_label text NOT NULL DEFAULT 'Referencia comunitaria · sin confirmar en terreno',
  is_demo boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX community_resources_location_idx ON public.community_resources USING gist(location);
CREATE INDEX community_resources_neighborhood_idx ON public.community_resources(neighborhood);

CREATE TABLE public.support_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 3 AND 120),
  description text NOT NULL CHECK (char_length(description) <= 600),
  neighborhood text NOT NULL DEFAULT 'Pueblo Libre',
  sector text NOT NULL DEFAULT 'Sector San Martín',
  coordinator_label text NOT NULL DEFAULT 'Coordinación vecinal voluntaria',
  channel_note text NOT NULL DEFAULT 'Grupo barrial informativo · No sustituye centrales de emergencia',
  is_demo boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX support_groups_neighborhood_idx ON public.support_groups(neighborhood);
