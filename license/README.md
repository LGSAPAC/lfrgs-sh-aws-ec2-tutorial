# License

Put your Liferay DXP activation key here as `license.xml`:

```bash
cp ~/Downloads/activation-key-dxp-*.xml license/license.xml
```

- `license/*.xml` is in `.gitignore`. **Never commit a license file**, and never paste it into chat, tickets or documents.
- `terraform apply` uploads it to the stack's private S3 bucket (`s3://<artifact-bucket>/license/license.xml`). Each Liferay instance copies it into Liferay's `deploy` folder at boot (`render-config.sh`).
- The `liferay/dxp` image ships its own single-node trial key, but `host/docker/compose.yaml` turns it off (`LIFERAY_CONTAINER_DISABLE_TRIAL_LICENSE`), so **your key is the only one**: without it, Liferay never becomes ready.
- **High availability needs a key that allows clustering.** Check `<license-type>` in the file:

| `<license-type>` | Works for | Example |
| --- | --- | --- |
| `developer` | Single mode only. Liferay refuses it in a cluster: `Developer licenses do not allow for clustering` | `DXP Development`, often with `<max-http-sessions>5</max-http-sessions>` |
| `virtual-cluster` | Single mode and HA, up to `<max-cluster-nodes>` nodes | `DXP Non-Production (Virtual Cluster)`, `<max-cluster-nodes>2</max-cluster-nodes>` (tested) |
| `developer-cluster`, `production`, `enterprise` | Depends on the subscription; look for a node or server count in the file | |

Check yours with `grep -E '<(license-type|license-name|max-cluster-nodes|max-http-sessions|expiration-date)>' license/license.xml`. Keep `liferay_node_count` at or below `<max-cluster-nodes>`. "Liferay Trial Activation" keys come in both kinds, so check the type rather than the account name.

  Ask your Liferay representative or Liferay Support if you need one.

To replace the license on a running stack:

```bash
terraform -chdir=terraform apply          # uploads the new file
scripts/run-on-stack.sh <stack> liferay 'sudo /opt/liferay-ec2/scripts/render-config.sh && (systemctl restart liferay 2>/dev/null || docker restart liferay)'
```
