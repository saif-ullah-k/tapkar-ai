// One-shot cleanup: deletes 3 real-user provider profiles + their
// user→provider mappings. Run with `node delete-test-providers.mjs`.
// Requires GOOGLE_APPLICATION_CREDENTIALS or `gcloud auth application-default login`.
import { Firestore } from '@google-cloud/firestore';

const PROJECT = process.env.GCP_PROJECT || 'fcmapp-30770';
const PROVIDER_IDS = [
  'p_user_vtbW45E3',
  'p_user_NXLhM2h2',
  'p_user_BDGS47H3',
];

const fs = new Firestore({ projectId: PROJECT });

async function main() {
  for (const pid of PROVIDER_IDS) {
    console.log(`\n--- ${pid} ---`);

    // 1. Read the provider doc so we can confirm + log before deleting.
    const pRef = fs.doc(`providers/${pid}`);
    const pSnap = await pRef.get();
    if (!pSnap.exists) {
      console.log(`  providers/${pid}: NOT FOUND, skipping`);
    } else {
      const p = pSnap.data();
      console.log(`  providers/${pid}: ${p.name} (${p.category}) in ${p.neighborhood}`);
    }

    // 2. Find which user_providers doc(s) map to this provider_id.
    const ownerSnap = await fs.collection('user_providers')
      .where('provider_id', '==', pid)
      .get();
    if (ownerSnap.empty) {
      console.log(`  user_providers → ${pid}: none found`);
    } else {
      for (const doc of ownerSnap.docs) {
        console.log(`  user_providers/${doc.id} → ${pid}: will delete`);
      }
    }

    // 3. Delete the owner mappings.
    for (const doc of ownerSnap.docs) {
      await doc.ref.delete();
      console.log(`  ✓ deleted user_providers/${doc.id}`);
    }

    // 4. Delete the provider doc itself.
    if (pSnap.exists) {
      await pRef.delete();
      console.log(`  ✓ deleted providers/${pid}`);
    }
  }

  console.log('\nDone. Refresh the providers list to confirm.');
}

main().catch((e) => {
  console.error('FAILED:', e?.message ?? e);
  process.exit(1);
});
