package com.example.frontend

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.io.OutputStream

class MainActivity : FlutterActivity() {
	private val channelName = "ln_tts/saf"
	private val pickTreeRequestCode = 7001

	private var pendingPickResult: MethodChannel.Result? = null

	private var nextHandle: Int = 1
	private val openReads: MutableMap<Int, InputStream> = mutableMapOf()
	private val openWrites: MutableMap<Int, OutputStream> = mutableMapOf()

	@Deprecated("Deprecated in Android", ReplaceWith(""))
	override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
		super.onActivityResult(requestCode, resultCode, data)
		if (requestCode != pickTreeRequestCode) return

		val res = pendingPickResult
		pendingPickResult = null
		if (res == null) return

		if (resultCode != Activity.RESULT_OK) {
			res.success(null)
			return
		}

		val uri = data?.data
		if (uri == null) {
			res.success(null)
			return
		}

		try {
			val flags = (data.flags
				and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION))
			contentResolver.takePersistableUriPermission(uri, flags)
		} catch (_: Exception) {
			// Best-effort; caller can still try to use it.
		}

		res.success(uri.toString())
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
			.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
				when (call.method) {
					"pickTree" -> {
						if (pendingPickResult != null) {
							result.error("busy", "Folder picker already active", null)
							return@setMethodCallHandler
						}
						pendingPickResult = result
						val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
							addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
							addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
							addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
							addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
						}
						@Suppress("DEPRECATION")
						startActivityForResult(intent, pickTreeRequestCode)
					}

					"persistPermission" -> {
						val treeUri = call.argument<String>("treeUri")
						if (treeUri.isNullOrBlank()) {
							result.error("bad_args", "treeUri is required", null)
							return@setMethodCallHandler
						}
						try {
							val uri = Uri.parse(treeUri)
							contentResolver.takePersistableUriPermission(
								uri,
								Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
							)
							result.success(null)
						} catch (e: Exception) {
							result.error("persist_failed", e.message, null)
						}
					}

					"exists" -> {
						try {
							val doc = resolveDoc(call)
							result.success(doc != null)
						} catch (e: Exception) {
							result.error("exists_failed", e.message, null)
						}
					}

					"delete" -> {
						try {
							val doc = resolveDoc(call)
							if (doc != null) {
								doc.delete()
							}
							result.success(null)
						} catch (e: Exception) {
							result.error("delete_failed", e.message, null)
						}
					}

					"listChildren" -> {
						try {
							val doc = resolveDoc(call)
							if (doc == null || !doc.isDirectory) {
								result.success(emptyList<String>())
								return@setMethodCallHandler
							}
							val names = doc.listFiles().mapNotNull { it.name }.toList()
							result.success(names)
						} catch (e: Exception) {
							result.error("list_failed", e.message, null)
						}
					}

					"openWrite" -> {
						try {
							val treeUri = call.argument<String>("treeUri")
							val path = call.argument<List<String>>("path")
							val mimeType = call.argument<String>("mimeType")
							val append = call.argument<Boolean>("append") ?: false
							if (treeUri.isNullOrBlank() || path == null || path.isEmpty() || mimeType.isNullOrBlank()) {
								result.error("bad_args", "treeUri, path, mimeType required", null)
								return@setMethodCallHandler
							}
							val fileDoc = resolveOrCreateFile(treeUri, path, mimeType)
							val mode = if (append) "wa" else "w"
							val os = contentResolver.openOutputStream(fileDoc.uri, mode)
								?: throw IllegalStateException("openOutputStream returned null")
							val handle = nextHandle++
							openWrites[handle] = os
							result.success(handle)
						} catch (e: Exception) {
							result.error("open_write_failed", e.message, null)
						}
					}

					"write" -> {
						try {
							val handle = call.argument<Int>("handle") ?: -1
							val bytes = call.argument<ByteArray>("bytes")
							val os = openWrites[handle]
							if (handle <= 0 || os == null || bytes == null) {
								result.error("bad_args", "invalid handle/bytes", null)
								return@setMethodCallHandler
							}
							os.write(bytes)
							result.success(null)
						} catch (e: Exception) {
							result.error("write_failed", e.message, null)
						}
					}

					"closeWrite" -> {
						val handle = call.argument<Int>("handle") ?: -1
						val os = openWrites.remove(handle)
						try {
							os?.flush()
							os?.close()
						} catch (_: Exception) {
						}
						result.success(null)
					}

					"openRead" -> {
						try {
							val doc = resolveDoc(call)
							if (doc == null || doc.isDirectory) {
								result.error("not_found", "file not found", null)
								return@setMethodCallHandler
							}
							val input = contentResolver.openInputStream(doc.uri)
								?: throw IllegalStateException("openInputStream returned null")
							val handle = nextHandle++
							openReads[handle] = input
							result.success(handle)
						} catch (e: Exception) {
							result.error("open_read_failed", e.message, null)
						}
					}

					"read" -> {
						try {
							val handle = call.argument<Int>("handle") ?: -1
							val maxBytes = call.argument<Int>("maxBytes") ?: 0
							val input = openReads[handle]
							if (handle <= 0 || input == null || maxBytes <= 0) {
								result.error("bad_args", "invalid handle/maxBytes", null)
								return@setMethodCallHandler
							}
							val buf = ByteArray(maxBytes)
							val n = input.read(buf)
							if (n <= 0) {
								result.success(ByteArray(0))
							} else if (n == buf.size) {
								result.success(buf)
							} else {
								result.success(buf.copyOf(n))
							}
						} catch (e: Exception) {
							result.error("read_failed", e.message, null)
						}
					}

					"closeRead" -> {
						val handle = call.argument<Int>("handle") ?: -1
						val input = openReads.remove(handle)
						try {
							input?.close()
						} catch (_: Exception) {
						}
						result.success(null)
					}

					else -> result.notImplemented()
				}
			}
	}

	private fun resolveDoc(call: MethodCall): DocumentFile? {
		val treeUri = call.argument<String>("treeUri")
		val path = call.argument<List<String>>("path")
		if (treeUri.isNullOrBlank() || path == null || path.isEmpty()) {
			throw IllegalArgumentException("treeUri and path are required")
		}
		val root = DocumentFile.fromTreeUri(this, Uri.parse(treeUri))
			?: throw IllegalStateException("Invalid treeUri")

		var cur: DocumentFile? = root
		for (segment in path) {
			if (cur == null || !cur.isDirectory) return null
			cur = cur.findFile(segment)
		}
		return cur
	}

	private fun resolveOrCreateFile(treeUri: String, path: List<String>, mimeType: String): DocumentFile {
		if (path.isEmpty()) throw IllegalArgumentException("path required")
		val root = DocumentFile.fromTreeUri(this, Uri.parse(treeUri))
			?: throw IllegalStateException("Invalid treeUri")

		var dir: DocumentFile = root
		for (i in 0 until (path.size - 1)) {
			val seg = path[i]
			val existing = dir.findFile(seg)
			dir = if (existing != null && existing.isDirectory) {
				existing
			} else {
				dir.createDirectory(seg) ?: throw IllegalStateException("Failed to create directory: $seg")
			}
		}

		val fileName = path[path.size - 1]
		val existing = dir.findFile(fileName)
		if (existing != null && existing.isFile) {
			return existing
		}
		if (existing != null) {
			// Name collision with a directory.
			existing.delete()
		}
		return dir.createFile(mimeType, fileName)
			?: throw IllegalStateException("Failed to create file: $fileName")
	}
}
