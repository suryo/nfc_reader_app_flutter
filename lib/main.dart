import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nfc_manager/nfc_manager.dart';

// Penting untuk akses kelas platform v4:
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';

// NDEF abstraction (lintas platform)
import 'package:nfc_manager_ndef/nfc_manager_ndef.dart';

void main() {
  runApp(const NFCReaderApp());
}

class NFCReaderApp extends StatelessWidget {
  const NFCReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NFC Reader',
      theme: ThemeData(useMaterial3: true),
      home: const NFCReaderPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class NFCReaderPage extends StatefulWidget {
  const NFCReaderPage({super.key});

  @override
  State<NFCReaderPage> createState() => _NFCReaderPageState();
}

class _NFCReaderPageState extends State<NFCReaderPage> {
  bool _isScanning = false;
  String _status = 'Tekan "Scan NFC", lalu tempelkan kartu/tag ke belakang HP.';
  String? _uidHex;
  String? _tech;
  String? _ndefSummary;

  @override
  void dispose() {
    NfcManager.instance.stopSession();
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _status = 'Memulai sesi NFC...';
      _uidHex = null;
      _tech = null;
      _ndefSummary = null;
    });

    final available = await NfcManager.instance.isAvailable();
    if (!available) {
      setState(() {
        _isScanning = false;
        _status = 'NFC tidak tersedia/aktif di perangkat ini.';
      });
      return;
    }

    await NfcManager.instance.startSession(
      // Aman untuk Android & iOS (FeliCa/iso18092 opsional: butuh entitlements tambahan di iOS)
      pollingOptions: {NfcPollingOption.iso14443, NfcPollingOption.iso15693},
      onDiscovered: (NfcTag tag) async {
        try {
          final uid = _extractIdentifier(tag);
          final techs = _detectTechs(tag).join(', ');
          final ndefInfo = await _tryReadNdef(tag);

          setState(() {
            _uidHex = uid;
            _tech = techs.isEmpty ? null : techs;
            _ndefSummary = ndefInfo;
            _status = uid == null
                ? 'Tag terdeteksi (UID mungkin tidak diekspos pada tipe/perangkat ini).'
                : 'Tag terdeteksi! UID: $uid';
          });
        } catch (e) {
          setState(() => _status = 'Gagal membaca tag: $e');
        } finally {
          await NfcManager.instance.stopSession();
          if (mounted) setState(() => _isScanning = false);
        }
      },
    );

    setState(() => _status = 'Tempelkan kartu/tag ke belakang HP…');
  }

  Future<void> _stopScan() async {
    await NfcManager.instance.stopSession();
    setState(() {
      _isScanning = false;
      _status = 'Sesi dihentikan.';
    });
  }

  /// Deteksi teknologi utama (kelas vendor-specific v4).
  List<String> _detectTechs(NfcTag tag) {
    final t = <String>[];

    // ---------- ANDROID ----------
    try {
      if (NfcAAndroid.from(tag) != null) t.add('NfcA');
      if (NfcBAndroid.from(tag) != null) t.add('NfcB');
      if (NfcFAndroid.from(tag) != null) t.add('NfcF');
      if (NfcVAndroid.from(tag) != null) t.add('NfcV');
      if (IsoDepAndroid.from(tag) != null) t.add('IsoDep');
      if (MifareClassicAndroid.from(tag) != null) t.add('MifareClassic');
      if (MifareUltralightAndroid.from(tag) != null) t.add('MifareUltralight');
      if (NdefAndroid.from(tag) != null) t.add('Ndef');
    } catch (_) {}

    // ---------- iOS ----------
    try {
      if (MiFareIos.from(tag) != null) t.add('MiFare');
      if (FeliCaIos.from(tag) != null) t.add('FeliCa');
      if (Iso15693Ios.from(tag) != null) t.add('Iso15693');
      if (Iso7816Ios.from(tag) != null) t.add('Iso7816');
      if (NdefIos.from(tag) != null) t.add('Ndef');
    } catch (_) {}

    return t;
  }

  /// Ambil UID (identifier) jika tersedia. iOS bisa berbeda/terbatas.
  String? _extractIdentifier(NfcTag tag) {
    Uint8List? id;

    // ---------- ANDROID: pakai NfcTagAndroid.id ----------
    final aTag = NfcTagAndroid.from(tag);
    if (aTag != null) {
      id = aTag.id; // UID/serial di Android v4
    }

    // ---------- iOS ----------
    id ??= MiFareIos.from(tag)?.identifier;
    id ??= FeliCaIos.from(tag)?.currentIDm;   // FeliCa punya IDm
    id ??= Iso15693Ios.from(tag)?.identifier;
    id ??= Iso7816Ios.from(tag)?.identifier;

    return id == null ? null : _bytesToHex(id);
  }

  /// Baca NDEF (pakai nfc_manager_ndef).
  Future<String?> _tryReadNdef(NfcTag tag) async {
    final ndef = Ndef.from(tag);
    if (ndef == null) return 'Tag tidak mendukung NDEF.';

    // Coba pakai pesan yang sudah di-cache saat discovery; jika null, read().
    final message = ndef.cachedMessage ?? await ndef.read(); // NdefMessage?

    if (message == null || message.records.isEmpty) return 'NDEF kosong.';

    final buf = StringBuffer();
    for (var i = 0; i < message.records.length; i++) {
      final r = message.records[i];
      buf.writeln('• Record #${i + 1}');
      buf.writeln('  TNF: ${r.typeNameFormat}');
      buf.writeln('  Type: ${String.fromCharCodes(r.type)}');
      if (r.payload.isNotEmpty) {
        final txt = _safePayloadPreview(r.payload);
        buf.writeln('  Payload: $txt');
      }
    }
    return buf.toString().trim();
  }

  String _safePayloadPreview(Uint8List bytes) {
    final s = String.fromCharCodes(bytes);
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  String _bytesToHex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    return sb.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('NFC Reader'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            // Panel UID besar + tombol salin
            if (_uidHex != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SelectableText(
                          'UID: ${_uidHex!}',
                          style: theme.textTheme.headlineSmall,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Salin UID',
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: _uidHex!));
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('UID disalin ke clipboard')),
                          );
                        },
                        icon: const Icon(Icons.copy),
                      ),
                    ],
                  ),
                ),
              ),

            // Status
            Text(_status, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 16),

            // Info Tech & NDEF
            if (_tech != null) _InfoTile(title: 'Tech', value: _tech!),
            if (_ndefSummary != null)
              _InfoTile(title: 'NDEF', value: _ndefSummary!),

            const SizedBox(height: 16),

            // Tombol aksi
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isScanning ? null : _startScan,
                    icon: const Icon(Icons.nfc),
                    label: const Text('Scan NFC'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isScanning ? _stopScan : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),
            Text(
              'Tips:\n'
              '• Gunakan perangkat nyata (emulator tidak mendukung NFC)\n'
              '• Aktifkan NFC di pengaturan\n'
              '• iOS: UID/identifier bisa terbatas tergantung jenis tag',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final String title;
  final String value;
  const _InfoTile({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SelectableText.rich(
          TextSpan(
            children: [
              TextSpan(text: '$title\n', style: theme.textTheme.titleSmall),
              TextSpan(text: value, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}
