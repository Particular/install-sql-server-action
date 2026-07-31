import * as path from 'node:path';
import * as url from 'node:url';
import * as core from '@actions/core';
import * as exec from '@actions/exec';

const __dirname = path.dirname(url.fileURLToPath(import.meta.url));

const setupPs1 = path.resolve(__dirname, '../setup.ps1');
const cleanupPs1 = path.resolve(__dirname, '../cleanup.ps1');

console.log('Setup path: ' + setupPs1);
console.log('Cleanup path: ' + cleanupPs1);

// Only one endpoint, so determine if this is the post action, and set it true so that
// the next time we're executed, it goes to the post action.
const isPost = core.getState('IsPost');
core.saveState('IsPost', true);

const connectionStringName = core.getInput('connection-string-env-var');
const catalog = core.getInput('catalog') || 'nservicebus';
const collation = core.getInput('collation') || 'SQL_Latin1_General_CP1_CS_AS';
const sqlServerVersion = core.getInput('sqlserver-version') || '2022';
const extraParams = core.getInput('extra-params') || '';
const enableFullTextSearch = core.getInput('enable-full-text-search') || 'false';
const enableDistributedTransactions = core.getInput('enable-distributed-transactions') || 'false';

async function run() {
    try {
        if (!isPost) {
            console.log('Running setup action');

            // Pin the container name to `sqlserver` so external tooling (and the CI verification
            // in .github/workflows/ci.yml) can address it without resolving state. Uniqueness
            // across jobs on a long-lived runner is handled by the cleanup post step.
            const containerName = 'sqlserver';
            core.saveState('ContainerName', containerName);

            console.log('containerName = ' + containerName);

            await exec.exec('pwsh', [
                '-File', setupPs1,
                '-ContainerName', containerName,
                '-ConnectionStringName', connectionStringName,
                '-Catalog', catalog,
                '-Collation', collation,
                '-SqlServerVersion', sqlServerVersion,
                '-ExtraParams', extraParams,
                '-EnableFullTextSearch', enableFullTextSearch,
                '-EnableDistributedTransactions', enableDistributedTransactions
            ]);
        } else {
            console.log('Running cleanup');

            const containerName = core.getState('ContainerName');
            const enableDistributedTransactionsState = core.getState('EnableDistributedTransactions');

            await exec.exec('pwsh', [
                '-File', cleanupPs1,
                '-ContainerName', containerName,
                '-EnableDistributedTransactions', enableDistributedTransactionsState
            ]);
        }
    } catch (err) {
        core.setFailed(err);
        console.log(err);
    }
}

run();
