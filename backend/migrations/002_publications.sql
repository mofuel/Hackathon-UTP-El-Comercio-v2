CREATE TABLE public.publications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_mutation_id uuid NOT NULL UNIQUE,
  author_id uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN (
    'anuncio', 'servicio', 'favor_solicitud', 'favor_oferta', 'prestamo',
    'donacion', 'habilidad', 'emergencia_solicitud', 'emergencia_oferta'
  )),
  category text NOT NULL DEFAULT 'general' CHECK (char_length(btrim(category)) BETWEEN 2 AND 50),
  title text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 3 AND 120),
  description text NOT NULL DEFAULT '' CHECK (char_length(description) <= 1000),
  neighborhood text NOT NULL DEFAULT 'Pueblo Libre' CHECK (char_length(btrim(neighborhood)) BETWEEN 2 AND 80),
  sector text NOT NULL DEFAULT 'Sector San Martín' CHECK (char_length(btrim(sector)) BETWEEN 2 AND 100),
  district_ubigeo text REFERENCES public.peru_districts(code),
  availability_text text NOT NULL DEFAULT '' CHECK (char_length(availability_text) <= 200),
  priority text NOT NULL DEFAULT 'normal' CHECK (priority IN ('normal', 'urgente', 'emergencia')),
  status text NOT NULL DEFAULT 'abierta' CHECK (status IN ('abierta', 'en_coordinacion', 'resuelta', 'cancelada')),
  approx_lat double precision CHECK (approx_lat BETWEEN -90 AND 90),
  approx_lng double precision CHECK (approx_lng BETWEEN -180 AND 180),
  location public.geography(Point, 4326) GENERATED ALWAYS AS (
    public.st_setsrid(public.st_makepoint(approx_lng, approx_lat), 4326)::public.geography
  ) STORED,
  service_lat double precision,
  service_lng double precision,
  service_address text NOT NULL DEFAULT '',
  share_service_location boolean NOT NULL DEFAULT false,
  share_resource_consent boolean NOT NULL DEFAULT false,
  recommendation_count integer NOT NULL DEFAULT 0 CHECK (recommendation_count >= 0),
  version integer NOT NULL DEFAULT 1 CHECK (version >= 1),
  is_demo boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CHECK ((approx_lat IS NULL) = (approx_lng IS NULL)),
  CHECK (author_id IS NOT NULL OR (kind = 'emergencia_solicitud' AND priority = 'emergencia')),
  CHECK (kind <> 'emergencia_oferta' OR share_resource_consent),
  CHECK (NOT share_service_location OR (
    kind = 'servicio' AND service_lat IS NOT NULL AND service_lng IS NOT NULL
    AND service_lat BETWEEN -85.05112878 AND 85.05112878 AND service_lng BETWEEN -180 AND 180
  ))
);

CREATE INDEX publications_location_idx ON public.publications USING gist(location)
  WHERE deleted_at IS NULL;
CREATE INDEX publications_feed_idx ON public.publications(district_ubigeo, created_at DESC, id DESC)
  WHERE deleted_at IS NULL;
CREATE INDEX publications_author_idx ON public.publications(author_id, created_at DESC);

CREATE FUNCTION public.normalize_publication_location()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF NOT NEW.share_service_location THEN
    NEW.service_lat := NULL;
    NEW.service_lng := NULL;
    NEW.service_address := '';
  ELSIF NEW.service_lat BETWEEN -85.05112878 AND 85.05112878
    AND NEW.service_lng BETWEEN -180 AND 180 THEN
    NEW.service_lat := round(NEW.service_lat::numeric, 6);
    NEW.service_lng := round(NEW.service_lng::numeric, 6);
    NEW.service_address := left(btrim(NEW.service_address), 300);
    NEW.approx_lat := NEW.service_lat;
    NEW.approx_lng := NEW.service_lng;
  END IF;
  IF NEW.approx_lat BETWEEN -90 AND 90 THEN
    NEW.approx_lat := public.round_public_coord(NEW.approx_lat);
  END IF;
  IF NEW.approx_lng BETWEEN -180 AND 180 THEN
    NEW.approx_lng := public.round_public_coord(NEW.approx_lng);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER normalize_publication_location BEFORE INSERT OR UPDATE ON public.publications
  FOR EACH ROW EXECUTE FUNCTION public.normalize_publication_location();

CREATE FUNCTION public.find_nearby_publications(
  origin_lat double precision, origin_lng double precision, radius_meters double precision
) RETURNS TABLE (
  id uuid, title text, kind text, category text, district_ubigeo text,
  distance_meters double precision
)
LANGUAGE sql STABLE STRICT
SET search_path = pg_catalog, public
AS $$
  WITH origin AS (
    SELECT st_setsrid(st_makepoint(origin_lng, origin_lat), 4326)::geography AS point
    WHERE origin_lat BETWEEN -90 AND 90 AND origin_lng BETWEEN -180 AND 180
      AND radius_meters BETWEEN 100 AND 20000
  )
  SELECT p.id, p.title, p.kind, p.category, p.district_ubigeo,
    st_distance(p.location, o.point) AS distance_meters
  FROM public.publications AS p
  CROSS JOIN origin AS o
  WHERE p.deleted_at IS NULL AND st_dwithin(p.location, o.point, radius_meters)
  ORDER BY distance_meters, p.created_at DESC, p.id
  LIMIT 200;
$$;
