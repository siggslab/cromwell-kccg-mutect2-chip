"""
Remove the CHIP pipeline outputs from the release bucket once no longer needed
"""
import hailtop.batch as hb
from cpg_utils.config import get_config
from cpg_utils.hail_batch import remote_tmpdir, get_batch

import re

VALID_PROJECTS = [
    'kccg-genomics-med',
]

_config = get_config()
DATASET = _config['workflow']['dataset']
JOB_NAME = _config['workflow']['name']
WORKFLOW_NAME = _config['workflow']['workflow_name']
RUN_ID = _config['workflow']['run_id']
CROMWELL_OUTPUT_BUCKET = _config['storage'][DATASET]['default']
# OUTPUT_BUCKET = _config['storage'][DATASET]['release']  # Currently no 'release' key in config TOML
OUTPUT_BUCKET = re.sub(r'\-main$', '-release', CROMWELL_OUTPUT_BUCKET)

# Check for valid buckets
if CROMWELL_OUTPUT_BUCKET not in [
    f'gs://cpg-{project}-main'
    for project in VALID_PROJECTS
]:
    raise ValueError(f'Invalid CROMWELL_OUTPUT_BUCKET: {CROMWELL_OUTPUT_BUCKET}')
if OUTPUT_BUCKET not in [
    f'gs://cpg-{project}-release'
    for project in VALID_PROJECTS
]:
    raise ValueError(f'Invalid OUTPUT_BUCKET: {OUTPUT_BUCKET}')


OUTPUT_PREFIX = f'{JOB_NAME}/{WORKFLOW_NAME}/{RUN_ID}'
CROMWELL_OUTPUT_PREFIX = f'mutect2-chip/{OUTPUT_PREFIX}'
OUTPUT_PATH = f'{OUTPUT_BUCKET}/{CROMWELL_OUTPUT_PREFIX}'

# Check for malformed paths
if not re.match(r'^gs://[A-Za-z0-9\-_\/\.]+$', OUTPUT_PATH):
    raise ValueError(f'Invalid OUTPUT_PATH: {OUTPUT_PATH}')

b = get_batch()

process_j = b.new_job('move-chip-output-files')

process_j.command(f"gcloud -q auth activate-service-account --key-file=/gsa-key/key.json; gsutil rm -r {OUTPUT_PATH}")

b.run(wait=False)