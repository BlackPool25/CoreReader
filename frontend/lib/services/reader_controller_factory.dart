import 'reader_stream_controller.dart';

import 'reader_controller_factory_stub.dart'
    if (dart.library.io) 'reader_controller_factory_io.dart';

ReaderStreamController createReaderController() {
  return createReaderControllerImpl();
}
