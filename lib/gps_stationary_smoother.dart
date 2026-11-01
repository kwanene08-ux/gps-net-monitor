import 'gps_anti_jump_filter.dart';

class GpsStationarySmoother {
  bool isStationary = false;

  GpsFixSample process(GpsFixSample sample) {
    return sample;
  }
}
