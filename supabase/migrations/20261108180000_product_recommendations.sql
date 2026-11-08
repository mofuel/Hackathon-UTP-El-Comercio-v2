begin;

create or replace function app_private.trg_recommendations_validate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  publication public.publications%rowtype;
begin
  if tg_op = 'UPDATE' and
      (new.user_id is distinct from old.user_id or
       new.publication_id is distinct from old.publication_id) then
    raise exception 'No se permite reasignar el autor o la publicación de una recomendación';
  end if;

  select * into publication
  from public.publications where id = new.publication_id;

  if publication.author_id is null then
    raise exception 'La publicación indicada no existe';
  end if;

  if publication.kind = 'anuncio' and publication.category = 'producto' then
    if publication.author_id = new.user_id then
      raise exception 'No puedes recomendar tu propio producto' using errcode = '42501';
    end if;
    if publication.deleted_at is not null then
      raise exception 'La publicación fue eliminada' using errcode = '42501';
    end if;
    if not exists (
      select 1 from public.profiles as neighbor
      where neighbor.id = new.user_id
        and neighbor.district_ubigeo = publication.district_ubigeo
        and nullif(lower(btrim(neighbor.sector)), '') =
            nullif(lower(btrim(publication.sector)), '')
    ) then
      raise exception 'Solo los vecinos del mismo distrito y sector pueden recomendar este producto'
        using errcode = '42501';
    end if;
  else
    if publication.kind <> 'servicio' then
      raise exception 'Solo se pueden recomendar servicios y productos del directorio';
    end if;
    if publication.author_id = new.user_id then
      raise exception 'No puedes recomendar tu propio servicio';
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

alter policy recommendations_insert_own on public.recommendations
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.publications p
      where p.id = publication_id
        and (p.kind = 'servicio' or (p.kind = 'anuncio' and p.category = 'producto'))
        and p.author_id <> (select auth.uid())
    )
  );

create or replace function app_private.trg_recommendations_recount()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  publication_id_to_update uuid := coalesce(new.publication_id, old.publication_id);
begin
  -- El ajuste atómico evita perder vistos buenos de productos en escrituras simultáneas.
  if exists (
    select 1 from public.publications
    where id = publication_id_to_update and kind = 'anuncio' and category = 'producto'
  ) then
    if tg_op = 'INSERT' then
      update public.publications set recommendation_count = recommendation_count + 1
      where id = publication_id_to_update;
    elsif tg_op = 'DELETE' then
      update public.publications set recommendation_count = greatest(0, recommendation_count - 1)
      where id = publication_id_to_update;
    end if;
  else
    update public.publications
    set recommendation_count = (
      select count(*)::int from public.recommendations
      where publication_id = publication_id_to_update
    )
    where id = publication_id_to_update;
  end if;
  return null;
end;
$$;

commit;
