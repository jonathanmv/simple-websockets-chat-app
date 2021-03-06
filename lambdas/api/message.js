const { debug, warn, error } = require('../helpers/log').buildLogger('API/MESSAGE');
const fail = require('../helpers/fail')(error)
const { assertNotEmpty, assertNoEmptyProperties } = require('../helpers/assertions')(error)
const { putMessage, connectionIdsByRoomId, latestMessagesInRoom } = require('./storage')
const { createBatch, trackBatch } = require('./eventTracker')
const { buildEvent, emitEvent, EventTypes } = require('./event')

const cleanupEvent = ({ meta, data }) => {
  const pick = (source, properties) => properties.reduce((prev, curr) => ({
    ...prev,
    [curr]: source[curr]
  }), {});

  const buildData = (source, props) => {
    const data = pick(source, props);
    assertNoEmptyProperties(data)
    return data
  }

  switch (meta.e) {
    case EventTypes.MESSAGE_SENT: {
      const cleanedData = buildData(data, ['messageId', 'roomId', 'authorId', 'text', 'createdAt'])
      return { meta, data: { ...cleanedData, authorName: data.authorName } };
    }
    case EventTypes.MESSAGE_BATCH_SENT: {
      return { meta, data };
    }
    case EventTypes.MESSAGE_REPLY_SENT: {
      const cleanedData = buildData(data, [ 'messageId', 'roomId', 'authorId', 'text', 'createdAt', 'toMessageId', 'toAuthorId', 'toText']);
      return { meta, data: { ...cleanedData, authorName: data.authorName } };
    }
    case EventTypes.MESSAGE_REACTION_SENT: {
      const remove = data.remove
      const cleanedData = buildData(data, [ 'roomId', 'authorId', 'reaction', 'createdAt', 'toMessageId']);
      return { meta, data: { ...cleanedData, remove } };
    }
    case EventTypes.MESSAGE_DELETED: {
      return { meta, data: buildData(data, ['messageId', 'roomId']) };
    }
    default:
      fail(`Invalid message event type: ` + meta.e);
  }
}

const findTargets = async (connectionId, { meta, data }) => {
  if (!connectionId) assertNotEmpty(connectionId)
  const connectionIds = (await connectionIdsByRoomId(data.roomId))
    .filter(id => id != connectionId);
  if (!connectionIds.length) {
    warn(`No targets found in room "${data.roomId}" for message type "${meta.e}"`)
    return [];
  }
  return connectionIds;
}

const broadcastEventInRoom = async (requestContext, systemEvent) => {
  const messageEvent = cleanupEvent(systemEvent);
  const connectionIds = await findTargets(requestContext.connectionId, systemEvent);
  if (!connectionIds.length) return;

  const { successful } = await emitEvent(requestContext, messageEvent, connectionIds);
  const batch = createBatch()
  successful.map(message => batch.pushEvent(EventTypes.MESSAGE_SENT, message))
  await trackBatch(batch);
}
exports.broadcastEventInRoom = broadcastEventInRoom

const broadcastConnectionsCountChangedInRooms = (requestContext, roomIds) => {
  return Promise.all(roomIds.map(roomId => {
    return broadcastConnectionsCountChangedInRoom(requestContext, roomId)
  }));
}
exports.broadcastConnectionsCountChangedInRooms = broadcastConnectionsCountChangedInRooms;

const broadcastConnectionsCountChangedInRoom = async (requestContext, roomId) => {
  const connectionIds = await connectionIdsByRoomId(roomId);
  const connectionsCount = connectionIds.length;
  if (!connectionsCount) {
    return;
  }

  const eventType = EventTypes.CONNECTIONS_COUNT_CHANGED;
  const data = { roomId, connectionsCount };
  const systemEvent = buildEvent(eventType, data);
  await emitEvent(requestContext, systemEvent, connectionIds);
}
exports.broadcastConnectionsCountChangedInRoom = broadcastConnectionsCountChangedInRoom;

exports.saveMessage = (requestContext, systemEvent) => {
  const messageEvent = cleanupEvent(systemEvent);
  return putMessage(messageEvent.data);
}

exports.latestMessagesInRoom = roomId => {
  return latestMessagesInRoom(roomId);
}
