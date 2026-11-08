import { readFile } from 'node:fs/promises';
import pg from 'pg';

const connectionString = process.env.DATABASE_URL;
if (!connectionString) throw new Error('Configura DATABASE_URL.');

const source = process.argv[2] ?? new URL('../../assets/geography/peru_ubigeo_2026.json', import.meta.url);
const catalog = await readFile(source, 'utf8');
const client = new pg.Client({ connectionString, connectionTimeoutMillis: 5000 });
await client.connect();

try {
  const { rowCount } = await client.query(`
    WITH departments AS (SELECT jsonb_array_elements($1::jsonb->'departments') AS item),
         provinces AS (SELECT jsonb_array_elements($1::jsonb->'provinces') AS item),
         districts AS (SELECT jsonb_array_elements($1::jsonb->'districts') AS item)
    INSERT INTO public.peru_districts (code, department, province, district, capital_lat, capital_lng)
    SELECT d.item->>0, department.item->>1, province.item->>1, d.item->>1,
           (d.item->>2)::double precision, (d.item->>3)::double precision
    FROM districts AS d
    JOIN provinces AS province ON province.item->>0 = left(d.item->>0, 4)
    JOIN departments AS department ON department.item->>0 = left(d.item->>0, 2)
    ON CONFLICT (code) DO UPDATE SET department = excluded.department, province = excluded.province,
      district = excluded.district, capital_lat = excluded.capital_lat, capital_lng = excluded.capital_lng
  `, [catalog]);
  console.log(`Distritos importados: ${rowCount}`);
} finally {
  await client.end();
}
