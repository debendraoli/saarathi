import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/widgets/common.dart';
import '../data/driver_kyc_repository.dart';
import '../domain/models.dart';

String docLabel(DocKind k) {
  switch (k) {
    case DocKind.profilePhoto:
      return 'Profile photo';
    case DocKind.citizenshipFront:
      return 'Citizenship (front)';
    case DocKind.citizenshipBack:
      return 'Citizenship (back)';
    case DocKind.license:
      return 'Driving license';
    case DocKind.bluebook:
      return 'Vehicle bluebook';
    case DocKind.vehiclePhoto:
      return 'Vehicle photo';
    case DocKind.insurance:
      return 'Insurance';
  }
}

class KycDocumentsScreen extends ConsumerWidget {
  const KycDocumentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final kyc = ref.watch(driverKycProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l.uploadDocuments)),
      body: kyc.when(
        loading: () => const LoadingView(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(driverKycProvider),
        ),
        data: (data) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatusBanner(status: data.status, reason: data.rejectionReason),
            const SizedBox(height: 16),
            for (final kind in DocKind.values)
              _DocRow(
                kind: kind,
                uploaded: data.uploadedKinds.contains(kind.wire),
              ),
            const SizedBox(height: 24),
            if (data.status == KycStatus.approved)
              FilledButton(
                onPressed: () => context.go(Routes.home),
                child: Text(l.actionDone),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.status, this.reason});
  final KycStatus status;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (icon, title, body, color) = switch (status) {
      KycStatus.approved => (
          Icons.verified_rounded,
          l.kycApproved,
          l.kycApprovedBody,
          scheme.primary,
        ),
      KycStatus.rejected => (
          Icons.error_rounded,
          l.kycRejected,
          reason ?? l.kycUnderReviewBody,
          scheme.error,
        ),
      _ => (
          Icons.hourglass_top_rounded,
          l.kycUnderReview,
          l.kycUnderReviewBody,
          scheme.tertiary,
        ),
    };
    return Card(
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(body, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DocRow extends ConsumerStatefulWidget {
  const _DocRow({required this.kind, required this.uploaded});
  final DocKind kind;
  final bool uploaded;

  @override
  ConsumerState<_DocRow> createState() => _DocRowState();
}

class _DocRowState extends ConsumerState<_DocRow> {
  bool _busy = false;

  Future<void> _capture() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_rounded),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('Gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final file =
        await ImagePicker().pickImage(source: source, imageQuality: 70);
    if (file == null) return;

    setState(() => _busy = true);
    try {
      await ref
          .read(driverKycRepositoryProvider)
          .uploadDocument(widget.kind.wire, file.path);
      ref.invalidate(driverKycProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppL10n.of(context).errorGeneric)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          widget.uploaded
              ? Icons.check_circle_rounded
              : Icons.upload_file_rounded,
          color: widget.uploaded ? scheme.primary : scheme.outline,
        ),
        title: Text(docLabel(widget.kind)),
        trailing: _busy
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            : TextButton(
                onPressed: _capture,
                child: Text(widget.uploaded
                    ? AppL10n.of(context).actionRetry
                    : 'Upload'),
              ),
      ),
    );
  }
}
