import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/attachment_upload_controller.dart';
void main(){test('rejects oversized image before upload',()async{final c=AttachmentUploadController();await c.validate(name:'a.jpg',mime:'image/jpeg',bytes:21*1024*1024);expect(c.state.status,AttachmentUploadStatus.failed);});}
