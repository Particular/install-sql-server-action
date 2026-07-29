using System.Transactions;
using Microsoft.Data.SqlClient;
using NUnit.Framework;

namespace Tests;

[TestFixture]
public class DistributedTransactionTests
{
    static string ConnectionString =>
        Environment.GetEnvironmentVariable("SQL_CONN_STR")
        ?? throw new InvalidOperationException("SQL_CONN_STR is not set.");

    [Test]
    public void Should_connect_and_run_a_simple_query()
    {
        using var connection = new SqlConnection(ConnectionString);
        connection.Open();

        using var command = connection.CreateCommand();
        command.CommandText = "SELECT 1";
        Assert.That(command.ExecuteScalar(), Is.EqualTo(1));
    }

    [Test]
    public void Should_commit_a_distributed_transaction()
    {
        // Enlist a second durable resource manager alongside SQL Server so the lightweight
        // transaction escalates to a full MSDTC-coordinated distributed transaction, then commit.
        // If the host's MSDTC (coordinator) and the container's SQL Server MSDTC can't coordinate
        // across the WSL2 boundary, Complete/Dispose throws -- the classic 0x8004D02B
        // "communication problems" error. This mirrors the NServiceBus SqlServer transport's own
        // startup self-check (FakePromotableResourceManager.ForceDtc).
        using var scope = new TransactionScope(
            TransactionScopeOption.RequiresNew,
            new TransactionOptions { IsolationLevel = IsolationLevel.ReadCommitted },
            TransactionScopeAsyncFlowOption.Enabled);

        var current = Transaction.Current ?? throw new InvalidOperationException("No ambient transaction.");
        current.EnlistDurable(Guid.NewGuid(), new DummyDurableResourceManager(), EnlistmentOptions.None);

        using var connection = new SqlConnection(ConnectionString);
        connection.Open();

        using var command = connection.CreateCommand();
        command.CommandText = "SELECT 1";
        command.ExecuteScalar();

        scope.Complete();
    }

    // A no-op durable resource manager. Enlisting it forces a second durable RM into the
    // transaction, which is what triggers promotion to MSDTC.
    sealed class DummyDurableResourceManager : IEnlistmentNotification
    {
        public void Prepare(PreparingEnlistment preparingEnlistment) => preparingEnlistment.Prepared();
        public void Commit(Enlistment enlistment) => enlistment.Done();
        public void Rollback(Enlistment enlistment) => enlistment.Done();
        public void InDoubt(Enlistment enlistment) => enlistment.Done();
    }
}