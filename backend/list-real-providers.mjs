// List all real (user-signed-up) provider docs straight from Firestore,
// bypassing the Cloud Run in-memory cache so we see fresh data.
import { Firestore } from '@google-cloud/firestore';

const fs = new Firestore({ projectId: process.env.GCP_PROJECT || 'fcmapp-30770' });

const snap = await fs.collection('providers').get();
const docs = snap.docs.map((d) => ({ id: d.id, ...d.data() }));
const real = docs.filter((d) => d.id.startsWith('p_user_'));
console.log(`Firestore has ${docs.length} provider docs total; ${real.length} are real signups.`);
for (const p of real) {
  console.log(`  ${p.id}  ${p.name ?? '(no name)'}  cat=${p.category ?? '?'}  area=${p.neighborhood ?? '?'}  phone=${p.phone ?? '?'}`);
}

const owners = await fs.collection('user_providers').get();
console.log(`\nuser_providers mappings: ${owners.size}`);
for (const d of owners.docs) {
  console.log(`  ${d.id} → ${d.data().provider_id}`);
}
