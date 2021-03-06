part of fs;

/**
 * A file or folder which exists on the google cloud servers.
 */
abstract class RemoteEntry {

  final CloudFilesystem filesystem;
  final String path;

  Map<String,String> _cachedMetadata;

  factory RemoteEntry(CloudFilesystem filesystem, String path) {
    if (_isFolderPath(path)) {
      return new RemoteFolder(filesystem, path);
    }
    return new RemoteFile(filesystem, path);
  }

  RemoteEntry._(this.filesystem, this.path):
    this._cachedMetadata = {};

  static final _FOLDER_REGEXP = new RegExp(r'/.');
  /**
   * The folder that contains the current entry.
   */
  RemoteFolder get parent =>
      new RemoteFolder(filesystem, path.substring(0, path.lastIndexOf(_FOLDER_REGEXP)));

  Future<bool> exists() {
    if (path == _FS_DELIMITER) return new Future.value(true);
    return filesystem.connection.getObject(
        filesystem.bucket,
        path,
        selector: "name")
    .then((result) => true)
    .catchError(
        (err) => false,
        test: (err) =>
            err is RPCException &&
            err.statusCode == HttpStatus.NOT_FOUND
    );
  }

  Future setEntryProperty(String key, String value) {
    return filesystem.connection.updateObject(
        filesystem.bucket,
        path,
        (object) => object.metadata[key] = value,
        readSelector: "metadata",
        resultSelector: "metadata"
    ).then((obj) => _cachedMetadata = obj.metadata);
  }

  Future<String> getEntryProperty(String key) {
    if (_cachedMetadata.containsKey(key))
      return new Future.value(_cachedMetadata[key]);
    return filesystem.connection.getObject(
        filesystem.bucket,
        path,
        selector: "metadata").then((object) {
      _cachedMetadata = object.metadata;
      return _cachedMetadata[key];
    });
  }

  /**
   * Get the google cloud storage metadata associated with the current
   * [RemoteEntry].
   *
   * The metadata of '/' is always `null`.
   */
  Future<StorageObject> metadata() =>
      path == _FS_DELIMITER
          ? new Future.value()
          : filesystem.connection.getObject(filesystem.bucket, path);



  /**
   * Delete the [RemoteEntry].
   */
  Future<RemoteEntry> delete({bool recursive: false});

  bool operator ==(Object other) => other is RemoteEntry && other.path == path;
  int get hashCode => path.hashCode * 7;
}

class RemoteFolder extends RemoteEntry {

  RemoteFolder(filesystem, String path):
    super._(filesystem, path) {
    _checkValidFolderPath(path);
  }

  /**
   * List all the [RemoteEntry]s in the current folder.
   */
  Stream<RemoteEntry> list() {
    return filesystem.connection.listBucket(
        filesystem.bucket,
        prefix: (this.path == _FS_DELIMITER ? "" : this.path),
        delimiter: _FS_DELIMITER,
        selector: "name"
    )
    .map((prefixOrObject) =>
        prefixOrObject.fold(
            ifLeft: (prefix) => new RemoteFolder(filesystem, prefix),
            ifRight: (obj) => new RemoteFile(filesystem, obj.path)
        )
    )
    .where((obj) => obj != this);
  }


  Future<bool> get isEmpty => list().isEmpty;

  /**
   * Create the folder if it does not exist.
   *
   * If [:recursive:] is `true` then the parent object of the [RemoteFolder] will
   * be created. Otherwise the future completes with a [FilesystemError]
   * if the parent does not exist.
   */
  Future<RemoteFolder> create({recursive: false}) {
    return exists().then((result) {
      if (result) {
        return this;
      } else {
        return parent.exists().then((result) {
          if (!result) {
            if (recursive) return parent.create(recursive: true);
            throw new FilesystemError.noSuchFolderOrFile(parent.path);
          }
        })
        .then((_) => filesystem.connection.uploadObject(filesystem.bucket, path, 'text/plain', new ByteSource([]), selector: "name"))
        .then((obj) => new RemoteFolder(filesystem, obj.name));
      }
    });
  }

  /**
   * Deletes the folder from the remote filesystem.
   *
   * If [:recursive:] is `false` then also delete the contents of the [RemoteFolder].
   * Otherwise, returns a future which completes with a [FilesystemError].
   */
  @override
  Future<RemoteFolder> delete({recursive: false}) {
    return isEmpty.then((result) {
      if (!result) {
        if (recursive) {
          return list().toList()
              .then((entries) => forEachAsync(
                  entries,
                  (entry) => entry.delete(recursive: true))
              );
        }
        throw new FilesystemError.folderNotEmpty(path);
      }
    })
    .then((_) => filesystem.connection.deleteObject(filesystem.bucket, path))
    .then((_) => this);
  }

  String toString() => "Folder: $path";
}

class RemoteFile extends RemoteEntry {


  RemoteFile(filesystem, path):
      super._(filesystem, path)  {
    _checkValidFilePath(path);
  }

  RemoteFile._from(RemoteFile file):
    super._(file.filesystem, file.path);


  /**
   * writes the [RemoteFile] to the server, overwriting any existing
   * content of the file.
   *
   * The file content is read from the given [Source].
   * [:contentType:] is the mime type of the source.
   */
  Future<RemoteFile> write(Source source, String contentType) {
    return filesystem.connection.uploadObject(
        filesystem.bucket,
        path,
        contentType,
        source,
        selector: "name"
    ).then((obj) => new RemoteFile(filesystem, obj.name));
  }

  /**
   * Reads the content of the file
   */
  Stream<List<int>> read([int start_or_end, int end]) {
    Range range = null;
    if (start_or_end != null) {
      if (start_or_end < 0) throw new RangeError.value(start_or_end);
      if (end != null) {
        if (end <= start_or_end) throw new RangeError.value(end);
        //A [Range] includes the index of the end byte.
        range = new Range(start_or_end, end - 1);
      } else {
        range = new Range(0, start_or_end - 1);
      }
    }
    return filesystem.connection.downloadObject(
        filesystem.bucket,
        path,
        byteRange: range);
  }

  /**
   * Create a copy of the [RemoteFile] to the specified filesystem location.
   * The destination does not necessarily need to be in the same fileysystem.
   *
   * Throws a [FilesystemError] if there is already an object at the specified
   * location.
   *
   * Returns a [Future] which completes with the created file if none exists,
   * or completes with a [FilesystemError] if the destination object exists.
   */
  Future<RemoteFile> copyTo(RemoteFile file) {
    return file.exists().then((result) {
      if (result) throw new FilesystemError.destinationExists(path);
      return metadata().then((mdata) {
      return filesystem.connection.copyObject(
          filesystem.bucket,
          this.path,
          file.filesystem.bucket,
          path,
          selector: 'name');
      })
      .then((obj) => new RemoteFile(filesystem, obj.name));
    });
  }

  /**
   * Move the [RemoteFile] to the specified fileysystem location.
   * The destination does not necessarily need to be in the same [Filesystem]
   * as the current file.
   *
   * Returns a [Future] which completes with the created file if none exists,
   * or completes with a [FilesystemError] if the destination object exists.
   */
  Future<RemoteFile> moveTo(RemoteFile file) {
    return copyTo(file)
        .then((file) {
          return delete().then((_) => file);
        });
  }

  /**
   * Delete the object from the filesystem.
   */
  Future<RemoteFile> delete({bool recursive: false}) =>
      filesystem.connection.deleteObject(
          filesystem.bucket,
          path)
      .then((_) => this);

  Future<int> get length =>
      filesystem.connection.getObject(filesystem.bucket, path, selector: "size")
      .then((result) => result.size);

  String toString() => "RemoteFile: $path";
}

bool _isFolderPath(String path) => path.endsWith(_FS_DELIMITER);


/**
 * A path is a '/' sepearated list of components, each of which cannot
 * be empty and which cannot contain a whitespace character
 */
final Pattern _VALID_PATH = new RegExp(r'/[^\s/](/[^\s/]|)*/?$');


void _checkValidFolderPath(String path) {
  if (_VALID_PATH.matchAsPrefix(path) == null)
    throw new PathError.invalidPath(path);
  if (!_isFolderPath(path))
    throw new PathError.invalidFolder(path);
}

void _checkValidFilePath(String path) {
  if (_VALID_PATH.matchAsPrefix(path) == null)
    throw new PathError.invalidPath(path);
  if (_isFolderPath(path))
    throw new PathError.invalidFile(path);
}

