import 'local_voice_list_stub.dart'
    if (dart.library.io) 'local_voice_list_io.dart';

Future<List<String>> loadLocalVoiceIds() => loadLocalVoiceIdsImpl();
