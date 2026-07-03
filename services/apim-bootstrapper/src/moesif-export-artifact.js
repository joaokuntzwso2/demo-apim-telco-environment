const fs = require('fs');
const path = require('path');

const BUNDLES_FILE = process.env.APIM_API_PRODUCT_BUNDLES_FILE || '/workspace/artifacts/apim-admin/api-product-bundles.json';
const OUTPUT_FILE = process.env.APIM_MOESIF_EXPORT_FILE || '/workspace/state/moesif-api-product-export.json';

function log(message) {
  console.log(`[APIM Moesif export artifact] ${message}`);
}

function main() {
  if (!fs.existsSync(BUNDLES_FILE)) {
    log(`bundle file not found: ${BUNDLES_FILE}`);
    return;
  }

  const bundles = JSON.parse(fs.readFileSync(BUNDLES_FILE, 'utf8'));

  const artifact = {
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
      productKey: bundle.moesif.productKey,
      name: bundle.name,
      description: bundle.description,
      businessStory: bundle.businessStory,
      businessOutcome: bundle.businessOutcome,
      buyer: bundle.buyer,
      companyId: bundle.moesif.companyId,
      billingCatalogReference: bundle.moesif.billingCatalogReference,
      revenueShareModel: bundle.moesif.revenueShareModel,
      settlementOwner: bundle.moesif.settlementOwner,
      productLine: bundle.moesif.productLine,
      markets: bundle.markets,
      plans: bundle.plans,
      apim: bundle.apim,
      apis: bundle.apiBundle,
      metadata: {
        wso2_api_product_name: bundle.apim.apiProductName,
        wso2_context: bundle.apim.context,
        wso2_governance_label: bundle.apim.governanceLabel,
        demo_storyline: bundle.businessStory
      }
    })),
    billingMeters: bundles.flatMap(bundle =>
      bundle.moesif.meters.map(meter => ({
        meterId: `${bundle.id}.${meter}`,
        productId: bundle.id,
        productKey: bundle.moesif.productKey,
        eventName: meter,
        aggregation: 'count',
        billable: true,
        revenueShareModel: bundle.moesif.revenueShareModel
      }))
    ),
    usageEventExamples: bundles.map(bundle => ({
      eventName: 'api_call',
      companyId: bundle.moesif.companyId,
      productKey: bundle.moesif.productKey,
      billingCatalogReference: bundle.moesif.billingCatalogReference,
      metadata: {
        api_product_bundle: bundle.name,
        business_outcome: bundle.businessOutcome,
        settlement_owner: bundle.moesif.settlementOwner
      }
    }))
  };

  fs.mkdirSync(path.dirname(OUTPUT_FILE), { recursive: true });
  fs.writeFileSync(OUTPUT_FILE, JSON.stringify(artifact, null, 2));
  log(`wrote ${OUTPUT_FILE}`);
  log(`products=${artifact.products.length}, meters=${artifact.billingMeters.length}`);
}

main();
