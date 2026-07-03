const fs = require('fs');
const path = require('path');

function readJson(candidates) {
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return JSON.parse(fs.readFileSync(candidate, 'utf8'));
    }
  }

  return null;
}

function buildMoesifExportFromBundles(bundles) {
  return {
    artifactType: 'moesif.billing_catalog.export',
    schemaVersion: 'telco-demo/v1',
    generatedAt: new Date().toISOString(),
    source: {
      system: 'WSO2 API Manager',
      description: 'API Product bundle metadata prepared for Moesif usage metering, billing and settlement.'
    },
    destination: {
      system: 'Moesif',
      purpose: 'Billing catalog alignment, product usage metering and revenue-share export.'
    },
    products: bundles.map(bundle => ({
      productId: bundle.id,
      productKey: bundle.moesif?.productKey,
      name: bundle.name,
      description: bundle.description,
      businessStory: bundle.businessStory,
      businessOutcome: bundle.businessOutcome,
      buyer: bundle.buyer,
      companyId: bundle.moesif?.companyId,
      billingCatalogReference: bundle.moesif?.billingCatalogReference,
      revenueShareModel: bundle.moesif?.revenueShareModel,
      settlementOwner: bundle.moesif?.settlementOwner,
      productLine: bundle.moesif?.productLine,
      markets: bundle.markets,
      plans: bundle.plans,
      apim: bundle.apim,
      apis: bundle.apiBundle || bundle.apis || []
    })),
    billingMeters: bundles.flatMap(bundle =>
      (bundle.moesif?.meters || []).map(meter => ({
        meterId: `${bundle.id}.${meter}`,
        productId: bundle.id,
        productKey: bundle.moesif?.productKey,
        eventName: meter,
        aggregation: 'count',
        billable: true,
        revenueShareModel: bundle.moesif?.revenueShareModel
      }))
    ),
    usageEventExamples: bundles.map(bundle => ({
      eventName: 'api_call',
      companyId: bundle.moesif?.companyId,
      productKey: bundle.moesif?.productKey,
      billingCatalogReference: bundle.moesif?.billingCatalogReference,
      metadata: {
        api_product_bundle: bundle.name,
        business_outcome: bundle.businessOutcome,
        settlement_owner: bundle.moesif?.settlementOwner
      }
    }))
  };
}

function registerDemoArtifactRoutes(app) {
  app.get('/api/v1/api-product-bundles', (req, res) => {
    const bundles = readJson([
      '/workspace/artifacts/apim-admin/api-product-bundles.json',
      path.join(process.cwd(), 'artifacts/apim-admin/api-product-bundles.json'),
      path.join(__dirname, '../../../artifacts/apim-admin/api-product-bundles.json')
    ]);

    if (!bundles) {
      return res.status(404).json({
        error: 'api_product_bundles_not_found'
      });
    }

    res.json({
      apiProductBundles: bundles
    });
  });

  app.get('/api/v1/moesif/export', (req, res) => {
    const exportArtifact = readJson([
      '/workspace/artifacts/exports/moesif-api-product-export.json',
      path.join(process.cwd(), 'artifacts/exports/moesif-api-product-export.json'),
      path.join(__dirname, '../../../artifacts/exports/moesif-api-product-export.json')
    ]);

    if (exportArtifact) {
      return res.json(exportArtifact);
    }

    const bundles = readJson([
      '/workspace/artifacts/apim-admin/api-product-bundles.json',
      path.join(process.cwd(), 'artifacts/apim-admin/api-product-bundles.json'),
      path.join(__dirname, '../../../artifacts/apim-admin/api-product-bundles.json')
    ]);

    if (!bundles) {
      return res.status(404).json({
        error: 'moesif_export_not_found'
      });
    }

    res.json(buildMoesifExportFromBundles(bundles));
  });
}

module.exports = {
  registerDemoArtifactRoutes
};
