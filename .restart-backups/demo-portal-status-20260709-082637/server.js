const express = require('express');
const app = express();
const port = Number(process.env.PORT || 8080);
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
