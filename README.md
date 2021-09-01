# cromwell-kccg-mutect2

Run the KCCG GATK4 Mutect2 somatic variant calling pipeline using the Cromwell workflow engine.

## Usage:

### Configuring Cromwell server

```bash
# Clone the repository into your working directory
git pull https://git.gimr.garvan.org.au/micgea/cromwell-kccg-mutect2.git
cd cromwell-kccg-mutect2

# Configure environment variables
MYSQL_HOST=localhost
MYSQL_PORT=40008
${PROJECT_NAME}="project_name"
CROMWELL_PORT=8000

# Run configuration script
./configure_cromwell.sh ${MYSQL_HOST} ${MYSQL_PORT} ${PROJECT_NAME} ${CROMWELL_PORT}
```

### Running Cromwell server

```bash
screen -S ${PROJECT_NAME}
./start_cromwell.sh
```

Once running, you can detatch the session with Ctrl + A, then D.

### Configuring workflow

Edit ./workflow/inputs.json in your favourite text editor. The input file is a series of key: value pairs. The template provided has values of "REQUIRED" and "OPTIONAL" for required and optional fields, respectively. If not using an optional parameter, simply delete the entire line. Some defaults are also provided and can be left as-is or changed if desired.

### Running the workflow

Once everything is set up and configured, run the workflow as follows:

```bash
./run.sh
```

You can check on the state of the run by re-attaching the Cromwell screen session:

```bash
screen -r ${PROJECT_NAME}
```