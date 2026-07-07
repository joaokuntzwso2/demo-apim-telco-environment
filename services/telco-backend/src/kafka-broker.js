const { Kafka, logLevel } = require('kafkajs');

const KAFKA_ENABLED = String(process.env.KAFKA_ENABLED || 'false').toLowerCase() === 'true';
const KAFKA_BROKERS = String(process.env.KAFKA_BROKERS || 'redpanda:9092')
  .split(',')
  .map(item => item.trim())
  .filter(Boolean);

const TOPICS = [
  'telco.network.qod.events',
  'telco.fraud.sim-swap.events',
  'telco.partner.settlement.events',
  'telco.runtime.policy.alerts'
];

const recentEvents = new Map(TOPICS.map(topic => [topic, []]));

const state = {
  enabled: KAFKA_ENABLED,
  connected: false,
  brokers: KAFKA_BROKERS,
  topics: TOPICS,
  implementation: 'Redpanda Kafka-compatible broker',
  lastError: null,
  startedAt: null
};

let started = false;
let producer = null;

function remember(topic, event) {
  const list = recentEvents.get(topic) || [];
  list.unshift(event);

  while (list.length > 25) {
    list.pop();
  }

  recentEvents.set(topic, list);
}

async function ensureKafkaStarted() {
  if (started) {
    return state;
  }

  started = true;

  if (!KAFKA_ENABLED) {
    state.lastError = 'KAFKA_ENABLED is not true';
    return state;
  }

  try {
    const kafka = new Kafka({
      clientId: process.env.KAFKA_CLIENT_ID || 'telco-demo-backend',
      brokers: KAFKA_BROKERS,
      logLevel: logLevel.NOTHING
    });

    const admin = kafka.admin();
    await admin.connect();

    const existing = await admin.listTopics();
    const missing = TOPICS.filter(topic => !existing.includes(topic));

    if (missing.length) {
      await admin.createTopics({
        waitForLeaders: true,
        topics: missing.map(topic => ({
          topic,
          numPartitions: 3,
          replicationFactor: 1
        }))
      });
    }

    await admin.disconnect();

    producer = kafka.producer();
    await producer.connect();

    const consumer = kafka.consumer({
      groupId: process.env.KAFKA_GROUP_ID || `telco-demo-ui-${Date.now()}`
    });

    await consumer.connect();

    for (const topic of TOPICS) {
      await consumer.subscribe({ topic, fromBeginning: true });
    }

    await consumer.run({
      eachMessage: async ({ topic, partition, message }) => {
        const raw = message.value ? message.value.toString() : '';

        let payload;
        try {
          payload = JSON.parse(raw);
        } catch {
          payload = raw;
        }

        remember(topic, {
          topic,
          partition,
          offset: message.offset,
          key: message.key ? message.key.toString() : null,
          consumedAt: new Date().toISOString(),
          payload
        });
      }
    });

    state.connected = true;
    state.startedAt = new Date().toISOString();
    state.lastError = null;
  } catch (error) {
    state.connected = false;
    state.lastError = error.message;
  }

  return state;
}

async function publishKafkaEvent(topic, event) {
  await ensureKafkaStarted();

  if (!producer || !state.connected) {
    const fallback = {
      delivered: false,
      mode: 'fallback',
      reason: state.lastError || 'Kafka producer is not connected',
      event
    };

    remember(topic, {
      topic,
      partition: null,
      offset: null,
      key: event.partnerId || event.eventId || topic,
      consumedAt: new Date().toISOString(),
      payload: event,
      fallback: true
    });

    return fallback;
  }

  const enriched = {
    ...event,
    kafka: {
      topic,
      producedBy: process.env.KAFKA_CLIENT_ID || 'telco-demo-backend',
      producedAt: new Date().toISOString()
    }
  };

  const result = await producer.send({
    topic,
    messages: [
      {
        key: enriched.partnerId || enriched.eventId || topic,
        value: JSON.stringify(enriched)
      }
    ]
  });

  remember(topic, {
    topic,
    partition: result[0]?.partition,
    offset: result[0]?.baseOffset,
    key: enriched.partnerId || enriched.eventId || topic,
    producedAt: enriched.kafka.producedAt,
    payload: enriched
  });

  return {
    delivered: true,
    mode: 'kafka',
    topic,
    broker: {
      type: 'Kafka protocol',
      implementation: 'Redpanda local demo broker',
      brokers: KAFKA_BROKERS
    },
    result,
    event: enriched
  };
}

async function kafkaStatus() {
  await ensureKafkaStarted();

  return {
    ...state,
    recentEventCounts: Object.fromEntries(
      Array.from(recentEvents.entries()).map(([topic, events]) => [topic, events.length])
    )
  };
}

async function recentKafkaEvents(topic) {
  await ensureKafkaStarted();

  return {
    topic,
    events: recentEvents.get(topic) || []
  };
}

module.exports = {
  kafkaTopics: TOPICS,
  kafkaStatus,
  publishKafkaEvent,
  recentKafkaEvents
};
