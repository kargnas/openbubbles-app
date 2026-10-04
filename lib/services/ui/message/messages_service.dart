import 'dart:async';

import 'package:bluebubbles/helpers/types/helpers/message_helper.dart';
import 'package:bluebubbles/helpers/types/constants.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart' hide Response;

MessagesService ms(String chatGuid) => Get.isRegistered<MessagesService>(tag: chatGuid)
    ? Get.find<MessagesService>(tag: chatGuid) : Get.put(MessagesService(chatGuid), tag: chatGuid);

String? lastReloadedChat() => Get.isRegistered<String>(tag: 'lastReloadedChat') ? Get.find<String>(tag: 'lastReloadedChat') : null;

class MessagesService extends GetxController {
  static final Map<String, Size> cachedBubbleSizes = {};
  late Chat chat;
  late StreamSubscription countSub;
  final ChatMessages struct = ChatMessages();
  late Function(Message) newFunc;
  late Function(Message, {String? oldGuid}) updateFunc;
  late Function(Message) removeFunc;
  late Function(String) jumpToMessage;

  final String tag;
  MessagesService(this.tag);

  /// highest message id in this chat seen by [_onDbChange], 0 until known
  int lastMaxId = 0;
  bool _dbChangeRunning = false;
  bool _dbChangePending = false;
  bool _changedWhileFetching = false;
  bool isFetching = false;
  bool _init = false;
  String? method;

  Message? get mostRecentSent => (struct.messages.where((e) => e.isFromMe!).toList()
      ..sort(Message.sort)).firstOrNull;

  Message? get mostRecent => (struct.messages.toList()
    ..sort(Message.sort)).firstOrNull;

  Message? get mostRecentReceived => (struct.messages.where((e) => !e.isFromMe!).toList()
    ..sort(Message.sort)).firstOrNull;

  void init(Chat c, Function(Message) onNewMessage, Function(Message, {String? oldGuid}) onUpdatedMessage, Function(Message) onDeletedMessage, Function(String) jumpToMessageFunc) {
    chat = c;
    Get.put<String>(tag, tag: 'lastReloadedChat');

    updateFunc = onUpdatedMessage;
    removeFunc = onDeletedMessage;
    newFunc = onNewMessage;
    jumpToMessage = jumpToMessageFunc;

    // watch for new messages
    if (!_init) {
      if (chat.id != null) {
        // one watcher per chat: ObjectBox only reports that the Message box
        // changed, so new and updated messages are both resolved off the UI
        // isolate in [_onDbChange]
        countSub = Database.messages.query().watch(triggerImmediately: true).listen((_) {
          // record at event time: the coalesced async sync may run after isFetching resets
          _changedWhileFetching |= isFetching;
          _onDbChange();
        });
      } else if (kIsWeb) {
        countSub = WebListeners.newMessage.listen((tuple) {
          if (tuple.item2?.guid == chat.guid) {
            _handleNewMessage(tuple.item1);
          }
        });
      }
    }
    _init = true;
  }

  @override
  void onClose() {
    if (_init) {
      countSub.cancel();
    }
    _init = false;
    super.onClose();
  }

  void close({force = false}) {
    String? lastChat = lastReloadedChat();
    if (force || lastChat != tag) {
      Get.delete<MessagesService>(tag: tag);
    }

    struct.flush();
  }

  void reload() {
    Get.put<String>(tag, tag: 'lastReloadedChat');
    Get.reload<MessagesService>(tag: tag);
  }

  /// Coalesces bursts of DB writes so only one lookup is in flight at a time
  Future<void> _onDbChange() async {
    if (_dbChangeRunning) {
      _dbChangePending = true;
      return;
    }
    _dbChangeRunning = true;
    try {
      do {
        _dbChangePending = false;
        await _syncWithDb();
      } while (_dbChangePending && _init);
    } catch (e, s) {
      Logger.error("Failed to sync chat messages with the DB", error: e, trace: s);
    } finally {
      _dbChangeRunning = false;
    }
  }

  Future<void> _syncWithDb() async {
    final changedWhileFetching = _changedWhileFetching;
    _changedWhileFetching = false;
    if (!ss.settings.finishedSetup.value) return;
    // loaded message controllers (and their reactions) that should get DB updates
    // every loaded message is re-read per Message box write (in a worker isolate)
    final controllers = <int, MessageWidgetController>{};
    final reactionParents = <int, MessageWidgetController>{};
    for (Message m in [...struct.messages, ...struct.threadOriginators]) {
      final c = getActiveMwc(m.guid!);
      if (c == null || c.message.id == null) continue;
      controllers[c.message.id!] = c;
      for (Message r in c.message.associatedMessages) {
        if (r.id != null) reactionParents[r.id!] = c;
      }
    }
    final ids = [...controllers.keys, ...reactionParents.keys];
    final args = (chat.id!, lastMaxId, ids);
    late final (List<Message>, List<Message?>, int) result;
    try {
      result = await Database.store.runAsync(_fetchChatChanges, args);
    } catch (e, s) {
      Logger.warn("Async chat message lookup failed, falling back to sync", error: e, trace: s);
      result = _fetchChatChanges(Database.store, args);
    }
    if (!_init) return;
    final (newMessages, loaded, maxId) = result;

    for (int i = 0; i < ids.length; i++) {
      final fresh = loaded[i];
      if (fresh == null) continue;
      final c = controllers[ids[i]];
      if (c != null) {
        if (!c.needsUpdate(fresh)) continue;
        if (fresh.hasAttachments) {
          fresh.attachments = List<Attachment>.from(fresh.dbAttachments);
        }
        fresh.associatedMessages = c.message.associatedMessages;
        fresh.handle = fresh.getHandle();
        c.updateMessage(fresh);
      } else {
        final parent = reactionParents[ids[i]]!;
        final old = parent.message.associatedMessages.firstWhereOrNull((e) => e.id == fresh.id);
        if (old != null && fresh.guid == old.guid && fresh.dateDelivered == old.dateDelivered) continue;
        parent.updateAssociatedMessage(fresh);
      }
    }

    // same rules as the old count watcher: ignore inserts made while loading
    // older chunks, and the very first lookup only records the current max
    // also skip if a fetch started while the worker lookup was pending (its inserts may be in newMessages)
    if (!changedWhileFetching && !_changedWhileFetching && !isFetching && lastMaxId != 0) {
      for (Message message in newMessages.reversed) {
        await _handleNewMessage(message);
      }
    }
    lastMaxId = maxId;
  }

  Future<void> _handleNewMessage(Message message) async {
    message.handle = message.getHandle();
    if (message.hasAttachments && !kIsWeb) {
      message.attachments = List<Attachment>.from(message.dbAttachments);
      // we may need an artificial delay in some cases since the attachment
      // relation is initialized after message itself is saved
      if (message.attachments.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 250));
        message.attachments = List<Attachment>.from(message.dbAttachments);
      }
    }
    // for sessions, we migrate metadata
    if (message.amkSessionId != null) {
      message.fetchAssociatedMessages();
    }
    // add this as a reaction if needed, update thread originators and associated messages
    if (message.associatedMessageGuid != null) {
      struct.getMessage(message.associatedMessageGuid!)?.associatedMessages.add(message);
      getActiveMwc(message.associatedMessageGuid!)?.updateAssociatedMessage(message);
    }
    if (message.threadOriginatorGuid != null) {
      getActiveMwc(message.threadOriginatorGuid!)?.updateThreadOriginator(message);
    }
    struct.addMessages([message]);
    if (message.associatedMessageGuid == null) {
      newFunc.call(message);
    }
  }

  void updateMessage(Message updated, {String? oldGuid}) {
    final toUpdate = struct.getMessage(oldGuid ?? updated.guid!);
    if (toUpdate == null) return;
    updated = updated.mergeWith(toUpdate);
    struct.removeMessage(oldGuid ?? updated.guid!);
    struct.removeAttachments(toUpdate.attachments.map((e) => e!.guid!));
    struct.addMessages([updated]);
    updateFunc.call(updated, oldGuid: oldGuid);
  }

  void removeMessage(Message toRemove) {
    struct.removeMessage(toRemove.guid!);
    struct.removeAttachments(toRemove.attachments.map((e) => e!.guid!));
    removeFunc.call(toRemove);
  }

  Future<bool> loadChunk(int offset, ConversationViewController controller, {int limit = 25}) async {
    isFetching = true;
    List<Message> _messages = [];
    offset = offset + struct.reactions.length;
    try {
      _messages = await Chat.getMessagesAsync(chat, offset: offset, limit: limit);
      if (_messages.isEmpty) {
        // get from server and save
        final fromServer = await cm.getMessages(chat.guid, offset: offset, limit: limit);
        final temp = await MessageHelper.bulkAddMessages(chat, fromServer, checkForLatestMessageText: false);
        if (!kIsWeb) {
          // re-fetch from the DB because it will find handles / associated messages for us
          _messages = await Chat.getMessagesAsync(chat, offset: offset, limit: limit);
        } else {
          final reactions = temp.where((e) => e.associatedMessageGuid != null);
          for (Message m in reactions) {
            final associatedMessage = temp.firstWhereOrNull((element) => element.guid == m.associatedMessageGuid);
            associatedMessage?.hasReactions = true;
            associatedMessage?.associatedMessages.add(m);
          }
          _messages = temp;
        }
      }
    } catch (e, s) {
      return Future.error(e, s);
    }

    struct.addMessages(_messages);
    // get thread originators
    for (Message m in _messages.where((e) => e.threadOriginatorGuid != null)) {
      // see if the originator is already loaded
      final guid = m.threadOriginatorGuid!;
      if (struct.getMessage(guid) != null) continue;
      // if not, fetch local and add to data
      final threadOriginator = Message.findOne(guid: guid);
      if (threadOriginator != null) {
        // create the controller so it can be rendered in a reply bubble
        final c = mwc(threadOriginator);
        c.cvController = controller;
        struct.addThreadOriginator(threadOriginator);
      }
    }
    // this indicates an audio message was kept by the recipient
    // run this every time more messages are loaded just in case
    for (Message m in struct.messages.where((e) => e.itemType == 5 && e.subject != null)) {
      final otherMessage = struct.getMessage(m.subject!);
      if (otherMessage != null) {
        final otherMwc = getActiveMwc(m.subject!) ?? mwc(otherMessage);
        otherMwc.audioWasKept.value = m.dateCreated;
      }
    }
    isFetching = false;
    return _messages.isNotEmpty;
  }

  Future<void> loadSearchChunk(Message around, SearchMethod method) async {
    isFetching = true;
    List<Message> _messages = [];
    if (method == SearchMethod.local) {
      _messages = await Chat.getMessagesAsync(chat, searchAround: around.dateCreated!.millisecondsSinceEpoch);
      _messages.add(around);
      _messages.sort(Message.sort);
      struct.addMessages(_messages);
    } else {
      final beforeResponse = await cm.getMessages(
        chat.guid,
        limit: 25,
        before: around.dateCreated!.millisecondsSinceEpoch,
      );
      final afterResponse = await cm.getMessages(
        chat.guid,
        limit: 25,
        sort: "ASC",
        after: around.dateCreated!.millisecondsSinceEpoch,
      );
      beforeResponse.addAll(afterResponse);
      _messages = beforeResponse.map((e) => Message.fromMap(e)).toList();
      _messages.sort(Message.sort);
      for (Message message in _messages) {
        if (message.handle != null) {
          message.handle!.contactRelation.target = cs.matchHandleToContact(message.handle!);
        }
      }
      struct.addMessages(_messages);
    }
    isFetching = false;
  }

  static Future<List<dynamic>> getMessages({
    bool withChats = false,
    bool withAttachments = false,
    bool withHandles = false,
    bool withChatParticipants = false,
    List<dynamic> where = const [],
    String sort = "DESC",
    int? before, int? after,
    String? chatGuid,
    int offset = 0, int limit = 100
  }) async {
    Completer<List<dynamic>> completer = Completer();
    final withQuery = <String>["attributedBody", "messageSummaryInfo", "payloadData"];
    if (withChats) withQuery.add("chat");
    if (withAttachments) withQuery.add("attachment");
    if (withHandles) withQuery.add("handle");
    if (withChatParticipants) withQuery.add("chat.participants");
    withQuery.add("attachment.metadata");

    http.messages(withQuery: withQuery, where: where, sort: sort, before: before, after: after, chatGuid: chatGuid, offset: offset, limit: limit).then((response) {
      if (!completer.isCompleted) completer.complete(response.data["data"]);
    }).catchError((err) {
      late final dynamic error;
      if (err is Response) {
        error = err.data["error"]["message"];
      } else {
        error = err?.toString();
      }
      if (!completer.isCompleted) completer.completeError(error ?? "");
    });

    return completer.future;
  }
}

/// Runs in an ObjectBox worker isolate, so only use [store] (not [Database]).
/// Returns messages of the chat newer than lastMaxId (only once lastMaxId is
/// known), the current state of the requested ids, and the chat's max id.
(List<Message>, List<Message?>, int) _fetchChatChanges(Store store, (int, int, List<int>) args) {
  final (chatId, lastMaxId, ids) = args;
  final box = store.box<Message>();
  return store.runInTransaction(TxMode.read, () {
    final query = (box.query(Message_.dateDeleted.isNull().and(Message_.id.greaterThan(lastMaxId)))
          ..link(Message_.chat, Chat_.id.equals(chatId))
          ..order(Message_.id))
        .build();
    final newIds = query.findIds();
    query.close();
    final newMessages = lastMaxId == 0 ? <Message>[] : box.getMany(newIds).whereNotNull().toList();
    return (newMessages, box.getMany(ids), newIds.lastOrNull ?? lastMaxId);
  });
}
