import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'services/route_service.dart';
import 'services/notification_service.dart';
import 'models/bus_model.dart';

String? selectedBusStopId;

class UpBusHomePage extends StatefulWidget {
  const UpBusHomePage({super.key});

  @override
  State<UpBusHomePage> createState() => _UpBusHomePageState();
}

class _UpBusHomePageState extends State<UpBusHomePage> {
  int _selectedRouteIndex = 0;
  int _selectedBottomIndex = 0;
  bool _notifyNearBusStop = false;

  final MapController _mapController = MapController();

  final DatabaseReference _gpsRef = FirebaseDatabase.instance.ref("GPS");

  // --- Multi-Bus Tracking Variables ---
  StreamSubscription? _busSubscription;
  StreamSubscription<Position>? _positionSubscription;

  List<Bus> _buses = [];
  Bus? _closestBus;
  LatLng? _userPosition;
  bool _hasAlerted = false; // ป้องกันการแจ้งเตือนซ้ำ

  static const double _alertDistanceMeters = 500.0;

  static const LatLng _kUniversity = LatLng(
    19.03011372185138,
    99.89781512200192,
  );

  @override
  void initState() {
    super.initState();
    _initializeServices();
    _listenToBusLocation();
    _startLocationTracking();
  }

  Future<void> _initializeServices() async {
    await NotificationService.initialize();
  }

  @override
  void dispose() {
    _busSubscription?.cancel();
    _positionSubscription?.cancel();
    super.dispose();
  }

  /// ติดตามตำแหน่งผู้ใช้
  Future<void> _startLocationTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    _positionSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
          ),
        ).listen((Position position) {
          if (!mounted) return;
          setState(() {
            _userPosition = LatLng(position.latitude, position.longitude);
          });
          _updateClosestBus();
        });
  }

  void _listenToBusLocation() {
    _busSubscription = _gpsRef.onValue.listen((event) {
      final data = event.snapshot.value;
      if (data == null || !mounted) return;

      List<Bus> newBuses = [];

      if (data is Map) {
        // รองรับหลายคัน: GPS/{busId}/lat, lng, name
        data.forEach((key, value) {
          if (value is Map &&
              value.containsKey('lat') &&
              value.containsKey('lng')) {
            try {
              newBuses.add(Bus.fromFirebase(key.toString(), value));
            } catch (e) {
              print('Error parsing bus $key: $e');
            }
          }
        });

        // Fallback: ถ้าไม่มี nested structure ให้ใช้แบบเดิม (single bus)
        if (newBuses.isEmpty &&
            data.containsKey('lat') &&
            data.containsKey('lng')) {
          newBuses.add(Bus.fromFirebase('bus_1', data));
        }
      }

      setState(() {
        _buses = newBuses;
      });
      _updateClosestBus();
    });
  }

  /// หาคันที่ใกล้ที่สุด + แจ้งเตือน
  Future<void> _updateClosestBus() async {
    if (_buses.isEmpty) return;

    final userPos = _userPosition ?? _kUniversity;
    final Distance distance = const Distance();

    // คำนวณระยะทางทุกคัน
    List<Bus> busesWithDistance = [];
    for (final bus in _buses) {
      // ลองใช้ road distance ก่อน, fallback เป็น straight-line
      double? roadDist = await RouteService.getRoadDistance(
        userPos,
        bus.position,
      );
      double dist =
          roadDist ?? distance.as(LengthUnit.Meter, userPos, bus.position);
      busesWithDistance.add(bus.copyWithDistance(dist));
    }

    // เรียงจากใกล้ไปไกล
    busesWithDistance.sort(
      (a, b) => (a.distanceToUser ?? double.infinity).compareTo(
        b.distanceToUser ?? double.infinity,
      ),
    );

    setState(() {
      _buses = busesWithDistance;
      _closestBus = busesWithDistance.isNotEmpty
          ? busesWithDistance.first
          : null;
    });

    // แจ้งเตือนถ้าเข้าใกล้กว่า 500 เมตร
    if (_notifyNearBusStop && _closestBus != null) {
      final closestDist = _closestBus!.distanceToUser ?? double.infinity;
      if (closestDist <= _alertDistanceMeters && !_hasAlerted) {
        _hasAlerted = true;
        await NotificationService.alertBusNearby(
          busName: _closestBus!.name,
          distanceMeters: closestDist,
        );
      } else if (closestDist > _alertDistanceMeters) {
        _hasAlerted = false; // Reset เมื่อออกนอกระยะ
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      endDrawer: _buildEndDrawer(),
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(context),
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            FlutterMap(
                              mapController: _mapController,
                              options: MapOptions(
                                initialCenter: _kUniversity,
                                initialZoom: 16.5,
                              ),
                              children: [
                                TileLayer(
                                  urlTemplate:
                                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                  userAgentPackageName: 'com.upbus.app',
                                ),
                                StreamBuilder(
                                  stream: FirebaseFirestore.instance
                                      .collection('Bus stop')
                                      .snapshots(),
                                  builder: (context, snapshot) {
                                    if (!snapshot.hasData)
                                      return const MarkerLayer(markers: []);
                                    return MarkerLayer(
                                      markers: snapshot.data!.docs.map((doc) {
                                        var data = doc.data();
                                        return Marker(
                                          point: LatLng(
                                            double.parse(
                                              data['lat'].toString(),
                                            ),
                                            double.parse(
                                              data['long'].toString(),
                                            ),
                                          ),
                                          // ขยาย width และ height เพื่อให้มีพื้นที่สำหรับแถบข้อความที่จะลอยขึ้นมา
                                          width: 200,
                                          height: 100,
                                          child: GestureDetector(
                                            onTap: () {
                                              setState(() {
                                                // เมื่อกดที่ป้าย: ถ้าเป็นป้ายเดิมให้ปิด (null) ถ้าเป็นป้ายใหม่ให้เปิด (เก็บ doc.id)
                                                selectedBusStopId =
                                                    (selectedBusStopId ==
                                                        doc.id)
                                                    ? null
                                                    : doc.id;
                                              });
                                            },
                                            child: Stack(
                                              alignment: Alignment.bottomCenter,
                                              children: [
                                                // --- ส่วนที่ 1: แถบข้อความสีขาว (จะแสดงเฉพาะป้ายที่ถูกเลือก) ---
                                                if (selectedBusStopId == doc.id)
                                                  Positioned(
                                                    top:
                                                        0, // ให้ลอยอยู่ด้านบนสุดของ Stack
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 10,
                                                            vertical: 5,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: Colors
                                                            .white, // พื้นหลังสีขาวตามรูป
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                        boxShadow: const [
                                                          BoxShadow(
                                                            color:
                                                                Colors.black26,
                                                            blurRadius: 4,
                                                            offset: Offset(
                                                              0,
                                                              2,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                      child: Text(
                                                        data['name']
                                                            .toString(), // ดึงชื่อป้ายจาก Firebase
                                                        style: const TextStyle(
                                                          color: Colors.black,
                                                          fontSize: 12,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                        ),
                                                      ),
                                                    ),
                                                  ),

                                                // --- ส่วนที่ 2: ไอคอนป้ายรถเมล์ (อยู่ด้านล่างเสมอ) ---
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        bottom: 10,
                                                      ),
                                                  child: Image.asset(
                                                    'assets/images/bus-stopicon.png',
                                                    width: 60,
                                                    height: 60,
                                                    fit: BoxFit.contain,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      }).toList(),
                                    );
                                  },
                                ),
                                // --- Live Bus Markers ---
                                MarkerLayer(
                                  markers: _buses.map((bus) {
                                    final isClosest = _closestBus?.id == bus.id;
                                    return Marker(
                                      point: bus.position,
                                      width: 45,
                                      height: 45,
                                      child: Image.asset(
                                        'assets/images/bus3icon.png',
                                        fit: BoxFit.contain,
                                      ),
                                    );
                                  }).toList(),
                                ),
                                // --- User Location Marker ---
                                if (_userPosition != null)
                                  MarkerLayer(
                                    markers: [
                                      Marker(
                                        point: _userPosition!,
                                        width: 50,
                                        height: 50,
                                        child: Stack(
                                          alignment: Alignment.center,
                                          children: [
                                            // วงกลมรัศมีแสดงความแม่นยำ
                                            Container(
                                              width: 40,
                                              height: 40,
                                              decoration: BoxDecoration(
                                                color: Colors.blue.withOpacity(
                                                  0.2,
                                                ),
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: Colors.blue
                                                      .withOpacity(0.5),
                                                  width: 2,
                                                ),
                                              ),
                                            ),
                                            // จุดตำแหน่งผู้ใช้
                                            Container(
                                              width: 16,
                                              height: 16,
                                              decoration: BoxDecoration(
                                                color: Colors.blue,
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: Colors.white,
                                                  width: 3,
                                                ),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: Colors.blue
                                                        .withOpacity(0.4),
                                                    blurRadius: 8,
                                                    spreadRadius: 2,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                            Positioned(
                              top: 16,
                              right: 16,
                              child: Column(
                                children: [
                                  _floatingMapIcon(
                                    icon: _notifyNearBusStop
                                        ? Icons.notifications_active
                                        : Icons.notifications_none,
                                    onTap: _onNotificationIconTap,
                                  ),
                                  const SizedBox(height: 12),
                                  _floatingMapIcon(
                                    icon: Icons.my_location,
                                    onTap: _goToMyLocation,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // --- Proximity Alert Box ---
                  if (_notifyNearBusStop && _closestBus != null)
                    Container(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade100,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.orange, width: 2),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.directions_bus,
                            color: Colors.orange,
                            size: 32,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '🚌 ${_closestBus!.name}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                                Text(
                                  'ระยะห่าง: ${_closestBus!.distanceToUser?.toStringAsFixed(0) ?? "N/A"} เมตร',
                                  style: TextStyle(
                                    color: Colors.grey.shade700,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if ((_closestBus!.distanceToUser ??
                                  double.infinity) <=
                              _alertDistanceMeters)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.orange,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                'ใกล้แล้ว!',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),

                  // ส่วนปุ่มเลือกสถานที่
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: _routeButton(
                            label: 'ภาพรวม',
                            color: Colors.black87,
                            isSelected: _selectedRouteIndex == 0,
                            onPressed: () =>
                                setState(() => _selectedRouteIndex = 0),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: _routeButton(
                            label: 'หน้ามอ',
                            color: Colors.blue.shade800,
                            isSelected: _selectedRouteIndex == 1,
                            onPressed: () {
                              setState(() => _selectedRouteIndex = 1);
                              _mapController.move(
                                const LatLng(19.028, 99.895),
                                17,
                              );
                            },
                          ),
                        ),
                        // ... ปุ่มอื่นๆ ...
                        const SizedBox(width: 6),
                        Expanded(
                          child: _routeButton(
                            label: 'หอใน',
                            color: Colors.amber.shade600,
                            isSelected: _selectedRouteIndex == 2,
                            onPressed: () =>
                                setState(() => _selectedRouteIndex = 2),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: _routeButton(
                            label: 'ICT',
                            color: Colors.red.shade600,
                            isSelected: _selectedRouteIndex == 3,
                            onPressed: () =>
                                setState(() => _selectedRouteIndex = 3),
                          ),
                        ),
                      ],
                    ),
                  ),

                  _buildBottomBar(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- ส่วนฟังก์ชันย่อยอื่นๆ (BottomBar ฯลฯ) คงเดิมตามที่แก้ล่าสุด ---

  // (คัดลอก Widget ย่อยด้านล่างจากโค้ดเดิมของคุณมาใส่ต่อได้เลยครับ)
  // ...

  Widget _routeButton({
    required String label,
    required Color color,
    required bool isSelected,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      height: 46,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: isSelected ? 6 : 2,
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Container(
      color: const Color(0xFF9C27B0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          const SizedBox(width: 8),
          const Text(
            'UP BUS',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.menu, color: Colors.white),
            onPressed: () => Scaffold.of(context).openEndDrawer(),
          ),
        ],
      ),
    );
  }

  Widget _buildEndDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            const ListTile(
              leading: CircleAvatar(child: Icon(Icons.person)),
              title: Text('Profile'),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Logout'),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _floatingMapIcon({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: Colors.grey.shade800),
        ),
      ),
    );
  }

  Future<void> _goToMyLocation() async {
    if (_userPosition != null) {
      _mapController.move(_userPosition!, 17);
    } else {
      // ถ้ายังไม่มีตำแหน่ง ให้ขอ permission อีกครั้ง
      await _startLocationTracking();
      if (_userPosition != null) {
        _mapController.move(_userPosition!, 17);
      }
    }
  }

  Future<void> _onNotificationIconTap() async {
    setState(() {
      _notifyNearBusStop = !_notifyNearBusStop;
      if (!_notifyNearBusStop) {
        _hasAlerted = false; // Reset alert state เมื่อปิด
      }
    });

    // แสดง SnackBar แจ้งสถานะ
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _notifyNearBusStop
              ? '🔔 เปิดการแจ้งเตือนรถบัสใกล้ (500 เมตร)'
              : '🔕 ปิดการแจ้งเตือนรถบัสใกล้',
        ),
        duration: const Duration(seconds: 2),
        backgroundColor: _notifyNearBusStop ? Colors.green : Colors.grey,
      ),
    );
  }

  // BottomBar ที่แก้ให้ใช้ Navigator แบบ Named Route แล้ว
  Widget _buildBottomBar() {
    return Container(
      color: const Color(0xFF9C27B0),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: SizedBox(
        height: 70,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _bottomNavItem(0, Icons.location_on, 'Live'),
            _bottomNavItem(1, Icons.directions_bus, 'Stop'),
            _bottomNavItem(2, Icons.map, 'Route'),
            _bottomNavItem(3, Icons.alt_route, 'Plan'),
            _bottomNavItem(4, Icons.feedback, 'Feed'),
          ],
        ),
      ),
    );
  }

  Widget _bottomNavItem(int index, IconData icon, String label) {
    final isSelected = _selectedBottomIndex == index;
    return InkWell(
      onTap: () {
        if (index == _selectedBottomIndex) return;
        switch (index) {
          case 0:
            break;
          case 1:
            Navigator.pushReplacementNamed(context, '/busStop');
            break;
          case 2:
            Navigator.pushReplacementNamed(context, '/route');
            break;
          case 3:
            Navigator.pushReplacementNamed(context, '/plan');
            break;
          case 4:
            Navigator.pushReplacementNamed(context, '/feedback');
            break;
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.white.withOpacity(0.2)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: isSelected ? 28 : 24),
            Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
