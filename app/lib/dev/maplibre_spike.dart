// Stage 0/1 spike for the maplibre_gl migration (see MapView's doc comment).
// Throwaway — proves the native SDK links and renders our real backend's
// vector tiles on a real device before any real screen depends on it. Not
// part of the shipped app; run directly with
// `flutter run -t lib/dev/maplibre_spike.dart`.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';

void main() => runApp(const SpikeApp());

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
        home: SpikeMapScreen(),
      );
}

class SpikeMapScreen extends StatefulWidget {
  const SpikeMapScreen({super.key});

  @override
  State<SpikeMapScreen> createState() => _SpikeMapScreenState();
}

class _SpikeMapScreenState extends State<SpikeMapScreen> {
  MapLibreMapController? _controller;
  String _status = 'loading style…';
  late final Future<String> _style =
      rootBundle.loadString('assets/dev/martin-style.json');

  Future<void> _onStyleLoaded() async {
    final controller = _controller;
    if (controller == null) return;
    // Ghorahi, Dang — same test point the smoke test uses.
    await controller.addSymbol(
      const SymbolOptions(
        geometry: LatLng(28.0336, 82.4836),
        iconImage: 'marker-15',
        iconSize: 2.0,
      ),
    );
    if (mounted) setState(() => _status = 'style loaded, marker placed');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('maplibre_gl spike — $_status')),
      body: FutureBuilder<String>(
        future: _style,
        builder: (context, snapshot) {
          final style = snapshot.data;
          if (style == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return MapLibreMap(
            // Stage 1: our own Martin-served vector tiles + the existing
            // recolored 47-layer style (deploy/tileserver/styles/saarathi),
            // repointed at Martin instead of tileserver-gl — passed as raw
            // JSON (maplibre_gl's own "option 4" for styleString) since
            // there's nothing serving this file over HTTP yet. Its "sources"
            // entry hardcodes this dev machine's LAN IP, fine for this
            // throwaway spike; the real client wiring (Stage 2/3) builds it
            // from AppConfig instead.
            styleString: style,
            initialCameraPosition: const CameraPosition(
              target: LatLng(28.0336, 82.4836),
              zoom: 12,
            ),
            onMapCreated: (c) => _controller = c,
            onStyleLoadedCallback: _onStyleLoaded,
            onMapClick: (point, latLng) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                      'tapped ${latLng.latitude.toStringAsFixed(4)}, '
                      '${latLng.longitude.toStringAsFixed(4)}'),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
