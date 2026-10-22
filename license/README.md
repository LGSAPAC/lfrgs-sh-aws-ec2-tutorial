# License

Put your Liferay DXP activation key here as `license.xml`:

```bash
cp ~/Downloads/activation-key-dxp-*.xml license/license.xml
```

- `license/*.xml` is in `.gitignore`. **Never commit a license file**, and never paste it into chat, tickets or documents.
- `terraform apply` uploads it to the stack's private S3 bucket (`s3://<artifact-bucket>/license/license.xml`). Each Liferay instance copies it into Liferay's `deploy` folder at boot (`render-config.sh`).
- The `liferay/dxp` 2026.Q1 LTS images and bundles have **no trial license**: without a key, Liferay never becomes ready.
- **High availability needs a license that allows clustering** (a production or cluster developer key). A single-node developer key makes the second node refuse to start or shut down. Ask your Liferay representative.

To replace the license on a running stack:

```bash
terraform -chdir=terraform apply          # uploads the new file
scripts/run-on-stack.sh <stack> liferay 'sudo /opt/liferay-ec2/scripts/render-config.sh && (systemctl restart liferay 2>/dev/null || docker restart liferay)'
```
