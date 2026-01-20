import 'package:latlong2/latlong.dart';

/// Model สำหรับเก็บข้อมูลรถบัส
class Bus {
  final String id;
  final String name;
  final LatLng position;
  double? distanceToUser; // ระยะห่างจากผู้ใช้ (เมตร)

  Bus({
    required this.id,
    required this.name,
    required this.position,
    this.distanceToUser,
  });

  /// สร้างจาก Firebase snapshot
  factory Bus.fromFirebase(String id, Map<dynamic, dynamic> data) {
    return Bus(
      id: id,
      name: data['name']?.toString() ?? 'สาย $id',
      position: LatLng(
        double.parse(data['lat'].toString()),
        double.parse(data['lng'].toString()),
      ),
    );
  }

  /// Copy with distance
  Bus copyWithDistance(double distance) {
    return Bus(
      id: id,
      name: name,
      position: position,
      distanceToUser: distance,
    );
  }
}
