const fs = require('fs');
const express = require('express');
const app = express();
app.use(express.json({limit: '32kb'}));
require('./telco-ai-routes')(app);
const port = Number(process.env.PORT || 8080);

const portalStateFile =
  process.env.APIM_PORTAL_STATE_FILE ||
  '/workspace/apim-portal-state/runtime.json';

function normalizedStateKey(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9]/g, '');
}

function findStateValue(value, expectedKeys) {
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findStateValue(
        item,
        expectedKeys
      );

      if (found) {
        return found;
      }
    }

    return '';
  }

  if (
    !value ||
    typeof value !== 'object'
  ) {
    return '';
  }

  for (const [key, child] of Object.entries(value)) {
    if (
      expectedKeys.has(
        normalizedStateKey(key)
      ) &&
      typeof child === 'string' &&
      child
    ) {
      return child;
    }
  }

  for (const child of Object.values(value)) {
    const found = findStateValue(
      child,
      expectedKeys
    );

    if (found) {
      return found;
    }
  }

  return '';
}

app.get('/portal-status', (_req, res) => {
  try {
    const raw = fs.readFileSync(
      portalStateFile,
      'utf8'
    );

    const state = JSON.parse(raw);

    const consumerKey = findStateValue(
      state,
      new Set([
        'consumerkey',
        'clientid'
      ])
    );

    const consumerSecret = findStateValue(
      state,
      new Set([
        'consumersecret',
        'clientsecret'
      ])
    );

    const hasConsumerKey =
      Boolean(consumerKey);

    const hasConsumerSecret =
      Boolean(consumerSecret);

    const ready =
      hasConsumerKey &&
      hasConsumerSecret;

    const stateObject =
      state &&
      typeof state === 'object' &&
      !Array.isArray(state)
        ? state
        : { runtimeState: state };

    res
      .status(ready ? 200 : 503)
      .json({
        ...stateObject,
        status:
          ready
            ? 'READY'
            : 'NOT_READY',
        hasConsumerKey,
        hasConsumerSecret
      });

  } catch (error) {
    res
      .status(503)
      .json({
        status: 'NOT_READY',
        hasConsumerKey: false,
        hasConsumerSecret: false,
        stateFile: portalStateFile,
        error: error.message
      });
  }
});

app.use((req, res, next) => {
  if (req.path === '/config.js') {
    res.type('application/javascript').send(`window.DEMO_CONFIG = ${JSON.stringify({
      backendUrl: process.env.TELCO_BACKEND_PUBLIC_URL || 'http://localhost:8081',
      pipelineUrl: process.env.PIPELINE_PUBLIC_URL || 'http://localhost:8090'
    })};`);
  } else next();
});
app.use(express.static('public'));
app.listen(port, () => console.log(`Telco demo portal running on ${port}`));
