class SupportMessage {
  const SupportMessage({
    required this.id,
    required this.senderRole,
    required this.body,
    this.tripId,
    this.createdAt,
  });

  final String id;
  final String senderRole; // user | staff
  final String body;
  final String? tripId;
  final DateTime? createdAt;

  bool get fromStaff => senderRole == 'staff';

  factory SupportMessage.fromJson(Map<String, dynamic> j) => SupportMessage(
        id: j['id'] as String,
        senderRole: (j['sender_role'] as String?) ?? 'user',
        body: (j['body'] as String?) ?? '',
        tripId: j['trip_id'] as String?,
        createdAt: j['created_at'] == null
            ? null
            : DateTime.tryParse(j['created_at'] as String),
      );
}
