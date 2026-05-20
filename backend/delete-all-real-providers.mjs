// Nuke every real (user-signed-up) provider and the user_providers
// ownership mapping. Leaves the mock seed providers alone.
import { Firestore } from '@google-cloud/firestore';

const fs = new Firestore({ projectId: process.env.GCP_PROJECT || 'fcmapp-30770' });

const pSnap = await fs.collection('providers').get();
const real = pSnap.docs.filter((d) => d.id.startsWith('p_user_'));
console.log(`Deleting ${real.length} real provider doc(s)...`);
for (const d of real) {
  await d.ref.delete();
  console.log(`  ✓ providers/${d.id}`);
}

const oSnap = await fs.collection('user_providers').get();
console.log(`\nDeleting ${oSnap.size} owner mapping(s)...`);
for (const d of oSnap.docs) {
  await d.ref.delete();
  console.log(`  ✓ user_providers/${d.id}`);
}

console.log('\nDone.');
