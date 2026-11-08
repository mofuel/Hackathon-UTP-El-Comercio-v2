begin;

insert into auth.users (id, email, raw_user_meta_data, role, aud)
values
  ('ca000000-0000-4000-8000-000000000001', 'autor.producto@example.invalid', '{"alias":"Autor"}', 'authenticated', 'authenticated'),
  ('ca000000-0000-4000-8000-000000000002', 'vecino.producto@example.invalid', '{"alias":"Vecino"}', 'authenticated', 'authenticated'),
  ('ca000000-0000-4000-8000-000000000003', 'sector.producto@example.invalid', '{"alias":"Otro sector"}', 'authenticated', 'authenticated'),
  ('ca000000-0000-4000-8000-000000000004', 'distrito.producto@example.invalid', '{"alias":"Otro distrito"}', 'authenticated', 'authenticated');

insert into public.profiles (id, alias, neighborhood, district_ubigeo, sector)
values
  ('ca000000-0000-4000-8000-000000000001', 'Autor', 'Pueblo Libre', '150121', 'Sector San Martín'),
  ('ca000000-0000-4000-8000-000000000002', 'Vecino', 'Pueblo Libre', '150121', '  sector san martín  '),
  ('ca000000-0000-4000-8000-000000000003', 'Otro sector', 'Pueblo Libre', '150121', 'Sector Plaza Bolívar'),
  ('ca000000-0000-4000-8000-000000000004', 'Otro distrito', 'Lima', '150101', 'Sector San Martín')
on conflict (id) do update
  set district_ubigeo = excluded.district_ubigeo, sector = excluded.sector;

insert into public.publications
  (id, client_mutation_id, author_id, kind, category, title, description, neighborhood, district_ubigeo, sector)
values
  ('cb000000-0000-4000-8000-000000000001', gen_random_uuid(), 'ca000000-0000-4000-8000-000000000001', 'anuncio', 'producto', 'Mochila', 'Precio S/ 10', 'Pueblo Libre', '150121', 'Sector San Martín'),
  ('cb000000-0000-4000-8000-000000000002', gen_random_uuid(), 'ca000000-0000-4000-8000-000000000001', 'servicio', 'general', 'Electricista', 'Servicio de prueba', 'Pueblo Libre', '150121', 'Sector San Martín');

set local role authenticated;

do $$
declare
  product constant uuid := 'cb000000-0000-4000-8000-000000000001';
  service constant uuid := 'cb000000-0000-4000-8000-000000000002';
  neighbor constant uuid := 'ca000000-0000-4000-8000-000000000002';
  author constant uuid := 'ca000000-0000-4000-8000-000000000001';
  other_sector constant uuid := 'ca000000-0000-4000-8000-000000000003';
  other_district constant uuid := 'ca000000-0000-4000-8000-000000000004';
  actor uuid;
  mutation constant uuid := gen_random_uuid();
begin
  foreach actor in array array[author, other_sector, other_district] loop
    perform set_config('request.jwt.claims', jsonb_build_object('sub', actor)::text, true);
    begin
      insert into public.recommendations(client_mutation_id, publication_id, user_id)
      values (gen_random_uuid(), product, actor);
      raise exception 'Se aceptó un visto bueno del autor o de otra zona';
    exception when insufficient_privilege then null;
    end;
  end loop;

  if (select recommendation_count from public.publications where id = product) <> 0 then
    raise exception 'Un visto bueno rechazado alteró el contador';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', neighbor)::text, true);
  insert into public.recommendations(client_mutation_id, publication_id, user_id)
  values (mutation, product, neighbor);
  insert into public.recommendations(client_mutation_id, publication_id, user_id, comment)
  values (mutation, product, neighbor, 'Buen producto')
  on conflict (client_mutation_id) do update set comment = excluded.comment;
  if (select recommendation_count from public.publications where id = product) <> 1 then
    raise exception 'Reintentar el visto bueno incrementó el contador';
  end if;
  begin
    insert into public.recommendations(client_mutation_id, publication_id, user_id)
    values (gen_random_uuid(), product, neighbor);
    raise exception 'Se aceptó un visto bueno duplicado';
  exception when unique_violation then null;
  end;

  delete from public.recommendations where client_mutation_id = mutation;
  if (select recommendation_count from public.publications where id = product) <> 0 then
    raise exception 'El retiro no redujo el contador';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', other_district)::text, true);
  insert into public.recommendations(client_mutation_id, publication_id, user_id)
  values (gen_random_uuid(), service, other_district);
  if (select recommendation_count from public.publications where id = service) <> 1 then
    raise exception 'Cambió el flujo previo de recomendaciones de servicios';
  end if;
end;
$$;

rollback;
