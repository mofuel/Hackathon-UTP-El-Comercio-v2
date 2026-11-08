import { BadRequestException, Controller, Get, Query } from '@nestjs/common';
import { Database } from './database';

function numberInRange(value: unknown, name: string, min: number, max: number) {
  if (typeof value !== 'string' || !/^-?\d+(?:\.\d+)?$/.test(value)) {
    throw new BadRequestException(`${name} debe ser un número decimal.`);
  }
  const number = Number(value);
  if (number < min || number > max) {
    throw new BadRequestException(`${name} debe estar entre ${min} y ${max}.`);
  }
  return number;
}

@Controller('api/v1/publications')
export class PublicationsController {
  constructor(private readonly database: Database) {}

  @Get('nearby')
  async nearby(
    @Query('lat') lat: unknown,
    @Query('lng') lng: unknown,
    @Query('radiusMeters') radiusMeters: unknown = '1000',
  ) {
    const { rows } = await this.database.pool.query(
      `select n.* from public.find_nearby_publications($1, $2, $3) n
       join public.publications p on p.id=n.id where p.is_demo
       order by n.distance_meters,p.created_at desc,p.id`,
      [
        numberInRange(lat, 'lat', -90, 90),
        numberInRange(lng, 'lng', -180, 180),
        numberInRange(radiusMeters, 'radiusMeters', 100, 20000),
      ],
    );
    return { publications: rows };
  }
}
