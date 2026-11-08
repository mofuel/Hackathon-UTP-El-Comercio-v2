REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;

CREATE FUNCTION public.round_public_coord(value double precision)
RETURNS double precision
LANGUAGE sql IMMUTABLE STRICT
SET search_path = pg_catalog
AS $$
  SELECT round(value::numeric, 3)::double precision;
$$;

CREATE TABLE public.peru_districts (
  code text PRIMARY KEY CHECK (code ~ '^[0-9]{6}$'),
  department text NOT NULL,
  province text NOT NULL,
  district text NOT NULL,
  capital_lat double precision CHECK (capital_lat BETWEEN -90 AND 90),
  capital_lng double precision CHECK (capital_lng BETWEEN -180 AND 180),
  CHECK ((capital_lat IS NULL) = (capital_lng IS NULL))
);

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  alias text NOT NULL CHECK (char_length(btrim(alias)) BETWEEN 2 AND 60),
  neighborhood text NOT NULL DEFAULT 'Pueblo Libre' CHECK (char_length(btrim(neighborhood)) BETWEEN 2 AND 80),
  sector text NOT NULL DEFAULT 'Sector San Martín' CHECK (char_length(btrim(sector)) BETWEEN 2 AND 100),
  district_ubigeo text REFERENCES public.peru_districts(code),
  bio text NOT NULL DEFAULT '' CHECK (char_length(bio) <= 280),
  approx_lat double precision CHECK (approx_lat BETWEEN -90 AND 90),
  approx_lng double precision CHECK (approx_lng BETWEEN -180 AND 180),
  use_gps_approx boolean NOT NULL DEFAULT false,
  share_resources_consent boolean NOT NULL DEFAULT false,
  is_demo boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((approx_lat IS NULL) = (approx_lng IS NULL))
);

CREATE TABLE public.profile_identities (
  issuer text NOT NULL,
  subject text NOT NULL,
  profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  PRIMARY KEY (issuer, subject)
);
CREATE INDEX profile_identities_profile_idx ON public.profile_identities(profile_id);

CREATE FUNCTION public.normalize_profile_coordinates()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF NEW.approx_lat BETWEEN -90 AND 90 THEN
    NEW.approx_lat := public.round_public_coord(NEW.approx_lat);
  END IF;
  IF NEW.approx_lng BETWEEN -180 AND 180 THEN
    NEW.approx_lng := public.round_public_coord(NEW.approx_lng);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER normalize_profile_coordinates
  BEFORE INSERT OR UPDATE OF approx_lat, approx_lng ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.normalize_profile_coordinates();
