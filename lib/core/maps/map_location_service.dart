import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'carto_basemap.dart';

/// Lectura puntual y voluntaria para el mapa.
class MapLocationService {
  Future<LatLng?> locate() => _locate(precise: false);

  /// El punto sin redondear se usa únicamente para el pin privado del mapa.
  Future<LatLng?> locatePrecise() => _locate(precise: true);

  Future<LatLng?> _locate({required bool precise}) async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        (precise &&
            permission == LocationPermission.whileInUse &&
            await Geolocator.getLocationAccuracy() ==
                LocationAccuracyStatus.reduced)) {
      permission = await Geolocator.requestPermission();
    }
    if (permission != LocationPermission.whileInUse &&
        permission != LocationPermission.always) {
      return null;
    }
    final position = await Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(
        accuracy: precise ? LocationAccuracy.high : LocationAccuracy.low,
        timeLimit: const Duration(seconds: 15),
      ),
    );
    final approximate = approximateMapPoint(
      position.latitude,
      position.longitude,
    );
    if (approximate == null || !precise) return approximate;
    return LatLng(position.latitude, position.longitude);
  }
}
