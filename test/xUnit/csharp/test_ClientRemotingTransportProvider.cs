// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System;
using System.Threading;
using System.Management.Automation;
using System.Management.Automation.Internal;
using System.Management.Automation.Remoting;
using System.Management.Automation.Remoting.Client;
using System.Management.Automation.Runspaces;
using System.Management.Automation.Runspaces.Internal;
using Xunit;

namespace PSTests.Parallel
{
    public static class ClientRemotingTransportProviderTests
    {
        [Fact]
        public static void ClientTransportOptionsAreCopiedFromSessionOptionsAndClone()
        {
            const string optionName = "Test:Option";
            object optionValue = new object();
            var options = new PSSessionOption();
            options.ClientTransportOptions.Add(optionName, optionValue);

            var connectionInfo = new WSManConnectionInfo();
            connectionInfo.SetSessionOptions(options);

            Assert.Same(optionValue, connectionInfo.ClientTransportOptions[optionName]);

            var copy = (WSManConnectionInfo)connectionInfo.Clone();

            Assert.Same(optionValue, copy.ClientTransportOptions[optionName]);
        }

        [Fact]
        public static void ProviderMustOptInToReplacingBuiltInConnectionInfo()
        {
            var provider = new TestProvider(_ => true);
            var connectionInfo = new WSManConnectionInfo();

            using (ClientRemotingTransportProviderRegistry.Register(provider))
            {
                Assert.False(ClientRemotingTransportProviderRegistry.WillUseRegisteredProvider(connectionInfo));
            }

            using (ClientRemotingTransportProviderRegistry.Register(
                provider,
                new ClientRemotingTransportProviderOptions { ReplaceBuiltInTransports = true }))
            {
                Assert.True(ClientRemotingTransportProviderRegistry.WillUseRegisteredProvider(connectionInfo));
            }
        }

        [Fact]
        public static void RegisteredProviderCreatesTransportForBuiltInConnectionInfoWhenReplacementIsEnabled()
        {
            var provider = new TestProvider(static connectionInfo => connectionInfo is WSManConnectionInfo);

            using (ClientRemotingTransportProviderRegistry.Register(
                provider,
                new ClientRemotingTransportProviderOptions { ReplaceBuiltInTransports = true }))
            using (RunspacePool runspacePool = RunspaceFactory.CreateRunspacePool(
                minRunspaces: 1,
                maxRunspaces: 1,
                connectionInfo: new WSManConnectionInfo(),
                host: null,
                typeTable: null,
                applicationArguments: null))
            {
                Assert.NotNull(runspacePool);
                Assert.Equal(1, provider.CreateSessionTransportCount);
            }
        }

        [Fact]
        public static void RunspacePoolFactoryAcceptsOptedInCustomConnectionInfo()
        {
            using RunspacePool runspacePool = RunspaceFactory.CreateRunspacePool(
                minRunspaces: 1,
                maxRunspaces: 1,
                connectionInfo: new CustomConnectionInfo(),
                host: null,
                typeTable: null,
                applicationArguments: null);

            Assert.NotNull(runspacePool);
        }

        [Fact]
        public static void RunspacePoolFactoryAcceptsProviderBackedConnectionInfo()
        {
            using (ClientRemotingTransportProviderRegistry.Register(new TestProvider(static connectionInfo => connectionInfo is PassiveConnectionInfo)))
            using (RunspacePool runspacePool = RunspaceFactory.CreateRunspacePool(
                minRunspaces: 1,
                maxRunspaces: 1,
                connectionInfo: new PassiveConnectionInfo(),
                host: null,
                typeTable: null,
                applicationArguments: null))
            {
                Assert.NotNull(runspacePool);
            }
        }

        [Fact]
        public static void RunspacePoolFactoryRejectsUnsupportedConnectionInfo()
        {
            Assert.Throws<NotSupportedException>(() => RunspaceFactory.CreateRunspacePool(
                minRunspaces: 1,
                maxRunspaces: 1,
                connectionInfo: new PassiveConnectionInfo(),
                host: null,
                typeTable: null,
                applicationArguments: null));
        }

        [Fact]
        public static void RunspacePoolFactoryStillRejectsSshConnectionInfoWithoutProvider()
        {
            Assert.Throws<NotSupportedException>(() => RunspaceFactory.CreateRunspacePool(
                minRunspaces: 1,
                maxRunspaces: 1,
                connectionInfo: new SSHConnectionInfo("user", "host", keyFilePath: null),
                host: null,
                typeTable: null,
                applicationArguments: null));
        }

        [Fact]
        public static void SessionTransportContextConstructorInitializesProtectedSurface()
        {
            var connectionInfo = new CustomConnectionInfo();
            var context = CreateContext(connectionInfo);
            var transportManager = new TestSessionTransportManager(context);

            Assert.Equal(context.RunspacePoolInstanceId, transportManager.GetRunspacePoolInstanceId());
            Assert.Same(connectionInfo, transportManager.GetTransportConnectionInfo());

            transportManager.SetFragmentSize(64 * 1024);

            Assert.Equal(64 * 1024, transportManager.GetFragmentSize());
        }

        [Fact]
        public static void ContextConstructorsValidateNullBeforeDelegating()
        {
            Assert.Throws<ArgumentNullException>(() => new TestSessionTransportManager(null));
            Assert.Throws<ArgumentNullException>(() => new TestCommandTransportManager(null));
        }

        [Fact]
        public static void TransportProtectedSurfaceValidatesInputs()
        {
            var context = CreateContext(new CustomConnectionInfo());
            var transportManager = new TestSessionTransportManager(context);

            Assert.Throws<ArgumentOutOfRangeException>(() => transportManager.SetFragmentSize(0));
            Assert.Throws<ArgumentOutOfRangeException>(() => transportManager.SetFragmentSize(-1));
            Assert.Throws<ArgumentNullException>(() => transportManager.ProcessIncomingData(null, ClientRemotingDataPriority.Default));
            Assert.Throws<ArgumentOutOfRangeException>(() => transportManager.ProcessIncomingData(Array.Empty<byte>(), (ClientRemotingDataPriority)99));
            Assert.Throws<ArgumentOutOfRangeException>(() => transportManager.ReportInvalidRobustConnectionNotification());
        }

        [Fact]
        public static void RegistryRejectsNullCustomConnectionInfoTransport()
        {
            var context = CreateContext(new NullCustomConnectionInfo());

            Assert.Throws<PSInvalidOperationException>(() => ClientRemotingTransportProviderRegistry.CreateSessionTransport(context));
        }

        [Fact]
        public static void RegistryRejectsNullProviderTransport()
        {
            var context = CreateContext(new PassiveConnectionInfo());

            using (ClientRemotingTransportProviderRegistry.Register(new NullTransportProvider()))
            {
                Assert.Throws<PSInvalidOperationException>(() => ClientRemotingTransportProviderRegistry.CreateSessionTransport(context));
            }
        }

        [Fact]
        public static void SessionTransportCanReadSdkQueuedData()
        {
            var context = CreateContext(new CustomConnectionInfo());
            var transportManager = new TestSessionTransportManager(context);
            var data = CreateTestRemoteDataObject(context.RunspacePoolInstanceId);

            transportManager.QueueDataToSend(data, ClientRemotingDataPriority.Default);

            byte[] bytes = transportManager.ReadNextDataToSend(
                registerCallbackIfNoDataAvailable: false,
                out ClientRemotingDataPriority priority);

            Assert.NotNull(bytes);
            Assert.NotEmpty(bytes);
            Assert.Equal(ClientRemotingDataPriority.Default, priority);
        }

        [Fact]
        public static void SessionTransportDoesNotDropQueuedDataWhenFragmentSizeChangeIsRejected()
        {
            var context = CreateContext(new CustomConnectionInfo());
            var transportManager = new TestSessionTransportManager(context);
            var data = CreateTestRemoteDataObject(context.RunspacePoolInstanceId);

            transportManager.QueueDataToSend(data, ClientRemotingDataPriority.Default);

            Assert.Throws<InvalidOperationException>(() => transportManager.SetFragmentSize(64 * 1024));

            byte[] bytes = transportManager.ReadNextDataToSend(
                registerCallbackIfNoDataAvailable: false,
                out ClientRemotingDataPriority priority);

            Assert.NotNull(bytes);
            Assert.NotEmpty(bytes);
            Assert.Equal(ClientRemotingDataPriority.Default, priority);
        }

        [Fact]
        public static void SessionTransportPreservesPendingCallbackWhenFragmentSizeChanges()
        {
            var context = CreateContext(new CustomConnectionInfo());
            var transportManager = new TestSessionTransportManager(context);
            var data = CreateTestRemoteDataObject(context.RunspacePoolInstanceId);
            using var dataAvailable = new ManualResetEventSlim();
            byte[] callbackData = null;
            ClientRemotingDataPriority callbackPriority = ClientRemotingDataPriority.PromptResponse;
            transportManager.DataToSendAvailableCallback = (bytes, priority) =>
            {
                callbackData = bytes.ToArray();
                callbackPriority = priority;
                dataAvailable.Set();
            };

            Assert.Null(transportManager.ReadNextDataToSend(
                registerCallbackIfNoDataAvailable: true,
                out _));

            transportManager.SetFragmentSize(64 * 1024);

            transportManager.QueueDataToSend(data, ClientRemotingDataPriority.Default);

            Assert.True(dataAvailable.Wait(TimeSpan.FromSeconds(5)));
            Assert.NotNull(callbackData);
            Assert.NotEmpty(callbackData);
            Assert.Equal(ClientRemotingDataPriority.Default, callbackPriority);
        }

        [Fact]
        public static void SessionTransportPreservesOutboundPromptResponsePriority()
        {
            var context = CreateContext(new CustomConnectionInfo());
            var transportManager = new TestSessionTransportManager(context);
            var data = CreateTestRemoteDataObject(context.RunspacePoolInstanceId);

            transportManager.QueueDataToSend(data, ClientRemotingDataPriority.PromptResponse);

            byte[] bytes = transportManager.ReadNextDataToSend(
                registerCallbackIfNoDataAvailable: false,
                out ClientRemotingDataPriority priority);

            Assert.NotNull(bytes);
            Assert.NotEmpty(bytes);
            Assert.Equal(ClientRemotingDataPriority.PromptResponse, priority);
        }

        [Fact]
        public static void LoopbackCustomTransportsExchangePsrpFragmentsThroughProtectedApis()
        {
            var context = CreateContext(new CustomConnectionInfo());
            var client = new LoopbackSessionTransportManager(context);
            var server = new LoopbackSessionTransportManager(context);
            var data = CreateTestRemoteDataObject(context.RunspacePoolInstanceId);
            using var dataReceived = new ManualResetEventSlim();
            RemoteDataObject<PSObject> receivedData = null;

            server.DataReceived += (source, args) =>
            {
                receivedData = args.ReceivedData;
                dataReceived.Set();
            };

            client.QueueDataToSend(data, ClientRemotingDataPriority.Default);
            client.PumpOutboundDataTo(server);

            Assert.True(dataReceived.Wait(TimeSpan.FromSeconds(5)));
            Assert.NotNull(receivedData);
            Assert.Equal(data.DataType, receivedData.DataType);
            Assert.Equal(data.RunspacePoolId, receivedData.RunspacePoolId);
        }

        [Fact]
        public static void SessionTransportProcessesReceivedDataWithTransportNeutralPriority()
        {
            var context = CreateContext(new CustomConnectionInfo());
            var sender = new TestSessionTransportManager(context);
            var receiver = new TestSessionTransportManager(context);
            var data = CreateTestRemoteDataObject(context.RunspacePoolInstanceId);
            using var dataReceived = new ManualResetEventSlim();
            RemoteDataObject<PSObject> receivedData = null;

            receiver.DataReceived += (source, args) =>
            {
                receivedData = args.ReceivedData;
                dataReceived.Set();
            };

            sender.QueueDataToSend(data, ClientRemotingDataPriority.PromptResponse);
            byte[] bytes = sender.ReadNextDataToSend(
                registerCallbackIfNoDataAvailable: false,
                out _);

            receiver.ProcessIncomingData(bytes, ClientRemotingDataPriority.PromptResponse);

            Assert.True(dataReceived.Wait(TimeSpan.FromSeconds(5)));
            Assert.NotNull(receivedData);
            Assert.Equal(data.DataType, receivedData.DataType);
            Assert.Equal(data.RunspacePoolId, receivedData.RunspacePoolId);
        }

        [Fact]
        public static void SessionTransportExposesDisconnectAndRetryCapabilities()
        {
            var context = CreateContext(new CustomConnectionInfo());
            var transportManager = new TestSessionTransportManager(context)
            {
                DisconnectSupported = true,
                RetryConnectionTime = 1234,
            };

            Assert.True(transportManager.GetSupportsDisconnect());
            Assert.Equal(1234, transportManager.GetMaxRetryConnectionTime());
        }

        [Fact]
        public static void CommandTransportContextExposesCommandText()
        {
            const string commandText = "Get-Process | Select-Object -First 1";
            var connectionInfo = new CustomConnectionInfo();
            var sessionContext = CreateContext(connectionInfo);
            var sessionTransportManager = new TestSessionTransportManager(sessionContext);
            using var powerShell = PowerShell.Create();
            powerShell.AddScript(commandText);
            using var runspacePool = RunspaceFactory.CreateRunspacePool(
                minRunspaces: 1,
                maxRunspaces: 1,
                connectionInfo: connectionInfo,
                host: null,
                typeTable: null,
                applicationArguments: null);
            powerShell.RunspacePool = runspacePool;
            using var remotePowerShell = new ClientRemotePowerShell(powerShell, runspacePool.RemoteRunspacePoolInternal);
            var commandContext = new ClientCommandTransportCreationContext(
                connectionInfo,
                remotePowerShell,
                noInput: true,
                sessionTransportManager,
                new PSRemotingCryptoHelperClient());

            Assert.Equal(commandText, commandContext.CommandText);

            using var commandTransportManager = new TestCommandTransportManager(commandContext);
            Assert.Equal(commandText, commandTransportManager.GetCommandText());
        }

        [Fact]
        public static void CommandTransportInitialDataCanRegisterForFutureCallback()
        {
            var connectionInfo = new CustomConnectionInfo();
            var sessionContext = CreateContext(connectionInfo);
            var sessionTransportManager = new TestSessionTransportManager(sessionContext);
            using var powerShell = PowerShell.Create();
            powerShell.AddScript("Get-Date");
            using var runspacePool = RunspaceFactory.CreateRunspacePool(
                minRunspaces: 1,
                maxRunspaces: 1,
                connectionInfo: connectionInfo,
                host: null,
                typeTable: null,
                applicationArguments: null);
            powerShell.RunspacePool = runspacePool;
            using var remotePowerShell = new ClientRemotePowerShell(powerShell, runspacePool.RemoteRunspacePoolInternal);
            var commandContext = new ClientCommandTransportCreationContext(
                connectionInfo,
                remotePowerShell,
                noInput: true,
                sessionTransportManager,
                new PSRemotingCryptoHelperClient());
            using var commandTransportManager = new TestCommandTransportManager(commandContext);
            using var dataAvailable = new ManualResetEventSlim();
            byte[] callbackData = null;
            ClientRemotingDataPriority callbackPriority = ClientRemotingDataPriority.PromptResponse;
            commandTransportManager.DataToSendAvailableCallback = (bytes, priority) =>
            {
                callbackData = bytes.ToArray();
                callbackPriority = priority;
                dataAvailable.Set();
            };

            while (commandTransportManager.ReadInitialData(registerCallbackIfNoDataAvailable: false) != null)
            {
            }

            Assert.Null(commandTransportManager.ReadInitialData(registerCallbackIfNoDataAvailable: true));

            commandTransportManager.QueueAdditionalInitialData(CreateTestRemoteDataObject(sessionContext.RunspacePoolInstanceId));

            Assert.True(dataAvailable.Wait(TimeSpan.FromSeconds(5)));
            Assert.NotNull(callbackData);
            Assert.NotEmpty(callbackData);
            Assert.Equal(ClientRemotingDataPriority.Default, callbackPriority);
        }

        [Fact]
        public static void CommandTransportInitialDataCanBeLoopedBackThroughProtectedApis()
        {
            var connectionInfo = new CustomConnectionInfo();
            var sessionContext = CreateContext(connectionInfo);
            var sessionTransportManager = new TestSessionTransportManager(sessionContext);
            var receiver = new LoopbackSessionTransportManager(sessionContext);
            using var powerShell = PowerShell.Create();
            powerShell.AddScript("Get-ChildItem");
            using var runspacePool = RunspaceFactory.CreateRunspacePool(
                minRunspaces: 1,
                maxRunspaces: 1,
                connectionInfo: connectionInfo,
                host: null,
                typeTable: null,
                applicationArguments: null);
            powerShell.RunspacePool = runspacePool;
            using var remotePowerShell = new ClientRemotePowerShell(powerShell, runspacePool.RemoteRunspacePoolInternal);
            var commandContext = new ClientCommandTransportCreationContext(
                connectionInfo,
                remotePowerShell,
                noInput: true,
                sessionTransportManager,
                new PSRemotingCryptoHelperClient());
            using var commandTransportManager = new TestCommandTransportManager(commandContext);
            using var dataReceived = new ManualResetEventSlim();
            RemoteDataObject<PSObject> receivedData = null;

            receiver.DataReceived += (source, args) =>
            {
                receivedData = args.ReceivedData;
                dataReceived.Set();
            };

            byte[] bytes = commandTransportManager.ReadInitialData(registerCallbackIfNoDataAvailable: false);
            Assert.NotNull(bytes);
            Assert.NotEmpty(bytes);

            receiver.ProcessIncomingData(bytes, ClientRemotingDataPriority.Default);

            Assert.True(dataReceived.Wait(TimeSpan.FromSeconds(5)));
            Assert.NotNull(receivedData);
            Assert.Equal(RemotingDataType.CreatePowerShell, receivedData.DataType);
            Assert.Equal(runspacePool.InstanceId, receivedData.RunspacePoolId);
        }

        [Fact]
        public static void SessionTransportCanReportLifecycleEvents()
        {
            var context = CreateContext(new CustomConnectionInfo());
            var transportManager = new TestSessionTransportManager(context);
            int connectCount = 0;
            int disconnectCount = 0;
            int reconnectCount = 0;
            int readyForDisconnectCount = 0;
            int delayStreamProcessedCount = 0;
            ConnectionStatus? connectionStatus = null;
            using var robustNotificationReceived = new ManualResetEventSlim();

            transportManager.ConnectCompleted += (source, args) => connectCount++;
            transportManager.DisconnectCompleted += (source, args) => disconnectCount++;
            transportManager.ReconnectCompleted += (source, args) => reconnectCount++;
            transportManager.ReadyForDisconnect += (source, args) => readyForDisconnectCount++;
            transportManager.DelayStreamRequestProcessed += (source, args) => delayStreamProcessedCount++;
            transportManager.RobustConnectionNotification += (source, args) =>
            {
                connectionStatus = args.Notification;
                robustNotificationReceived.Set();
            };

            transportManager.ReportLifecycleEventsForTest();

            Assert.Equal(1, connectCount);
            Assert.Equal(1, disconnectCount);
            Assert.Equal(1, reconnectCount);
            Assert.Equal(1, readyForDisconnectCount);
            Assert.Equal(1, delayStreamProcessedCount);
            Assert.True(robustNotificationReceived.Wait(TimeSpan.FromSeconds(5)));
            Assert.Equal(ConnectionStatus.ConnectionRetryAttempt, connectionStatus);
        }

        private static ClientRemotingTransportCreationContext CreateContext(RunspaceConnectionInfo connectionInfo)
        {
            return new ClientRemotingTransportCreationContext(
                Guid.NewGuid(),
                "test-session",
                connectionInfo,
                new PSRemotingCryptoHelperClient());
        }

        private static RemoteDataObject<PSObject> CreateTestRemoteDataObject(Guid runspacePoolInstanceId)
        {
            return RemoteDataObject<PSObject>.CreateFrom(
                RemotingDestination.Client,
                RemotingDataType.ApplicationPrivateData,
                runspacePoolInstanceId,
                Guid.Empty,
                PSObject.AsPSObject(new PSPrimitiveDictionary()));
        }

        private sealed class TestProvider : IClientRemotingTransportProvider
        {
            private readonly Func<RunspaceConnectionInfo, bool> _canCreateTransport;

            internal TestProvider(Func<RunspaceConnectionInfo, bool> canCreateTransport)
            {
                _canCreateTransport = canCreateTransport;
            }

            internal int CreateSessionTransportCount { get; private set; }

            public bool CanCreateTransport(RunspaceConnectionInfo connectionInfo)
            {
                return _canCreateTransport(connectionInfo);
            }

            public BaseClientSessionTransportManager CreateSessionTransport(ClientRemotingTransportCreationContext context)
            {
                CreateSessionTransportCount++;
                return new TestSessionTransportManager(context);
            }
        }

        private sealed class NullTransportProvider : IClientRemotingTransportProvider
        {
            public bool CanCreateTransport(RunspaceConnectionInfo connectionInfo)
            {
                return true;
            }

            public BaseClientSessionTransportManager CreateSessionTransport(ClientRemotingTransportCreationContext context)
            {
                return null;
            }
        }

        private class PassiveConnectionInfo : RunspaceConnectionInfo
        {
            public override string ComputerName { get; set; } = "passive";

            public override PSCredential Credential { get; set; }

            public override AuthenticationMechanism AuthenticationMechanism { get; set; }

            public override string CertificateThumbprint { get; set; }

            public override RunspaceConnectionInfo Clone()
            {
                var clone = new PassiveConnectionInfo();
                CopyClientTransportOptionsTo(clone);
                return clone;
            }
        }

        private sealed class CustomConnectionInfo : PassiveConnectionInfo
        {
            protected internal override bool CanCreateClientRemotingTransport => true;

            public override BaseClientSessionTransportManager CreateClientSessionTransportManager(
                ClientRemotingTransportCreationContext context)
            {
                return new TestSessionTransportManager(context);
            }

            public override RunspaceConnectionInfo Clone()
            {
                var clone = new CustomConnectionInfo();
                CopyClientTransportOptionsTo(clone);
                return clone;
            }
        }

        private sealed class NullCustomConnectionInfo : PassiveConnectionInfo
        {
            protected internal override bool CanCreateClientRemotingTransport => true;

            public override BaseClientSessionTransportManager CreateClientSessionTransportManager(
                ClientRemotingTransportCreationContext context)
            {
                return null;
            }
        }

        private sealed class TestSessionTransportManager : BaseClientSessionTransportManager
        {
            internal TestSessionTransportManager(ClientRemotingTransportCreationContext context)
                : base(context)
            {
            }

            public override void CreateAsync()
            {
            }

            protected internal override void ConnectAsync()
            {
            }

            internal bool DisconnectSupported { get; set; }

            protected internal override bool SupportsDisconnect => DisconnectSupported;

            internal int RetryConnectionTime { get; set; }

            protected internal override int MaxRetryConnectionTime => RetryConnectionTime;

            internal Action<ReadOnlyMemory<byte>, ClientRemotingDataPriority> DataToSendAvailableCallback { get; set; }

            protected override void OnDataToSendAvailable(
                ReadOnlyMemory<byte> data,
                ClientRemotingDataPriority priority)
            {
                DataToSendAvailableCallback?.Invoke(data, priority);
            }

            internal void QueueDataToSend(
                RemoteDataObject<PSObject> data,
                ClientRemotingDataPriority priority)
            {
                DataToBeSentCollection.Add(
                    data,
                    priority == ClientRemotingDataPriority.PromptResponse
                        ? DataPriorityType.PromptResponse
                        : DataPriorityType.Default);
            }

            internal byte[] ReadNextDataToSend(
                bool registerCallbackIfNoDataAvailable,
                out ClientRemotingDataPriority priority)
            {
                return ReadDataToSend(registerCallbackIfNoDataAvailable, out priority);
            }

            internal void ProcessIncomingData(byte[] data, ClientRemotingDataPriority priority)
            {
                ProcessReceivedData(data, priority);
            }

            internal void ReportInvalidRobustConnectionNotification()
            {
                ReportRobustConnectionNotification((ConnectionStatus)99);
            }

            internal void ReportLifecycleEventsForTest()
            {
                CompleteConnect();
                CompleteDisconnect();
                CompleteReconnect();
                CompleteReadyForDisconnect();
                CompleteDelayStreamProcessed();
                ReportRobustConnectionNotification(ConnectionStatus.ConnectionRetryAttempt);
            }

            internal Guid GetRunspacePoolInstanceId()
            {
                return RunspacePoolInstanceId;
            }

            internal RunspaceConnectionInfo GetTransportConnectionInfo()
            {
                return TransportConnectionInfo;
            }

            internal int GetFragmentSize()
            {
                return FragmentSize;
            }

            internal void SetFragmentSize(int fragmentSize)
            {
                FragmentSize = fragmentSize;
            }

            internal bool GetSupportsDisconnect()
            {
                return SupportsDisconnect;
            }

            internal int GetMaxRetryConnectionTime()
            {
                return MaxRetryConnectionTime;
            }
        }

        private sealed class LoopbackSessionTransportManager : BaseClientSessionTransportManager
        {
            internal LoopbackSessionTransportManager(ClientRemotingTransportCreationContext context)
                : base(context)
            {
            }

            public override void CreateAsync()
            {
            }

            protected internal override void ConnectAsync()
            {
            }

            internal void QueueDataToSend(
                RemoteDataObject<PSObject> data,
                ClientRemotingDataPriority priority)
            {
                DataToBeSentCollection.Add(
                    data,
                    priority == ClientRemotingDataPriority.PromptResponse
                        ? DataPriorityType.PromptResponse
                        : DataPriorityType.Default);
            }

            internal void PumpOutboundDataTo(LoopbackSessionTransportManager peer)
            {
                byte[] data;
                while ((data = ReadDataToSend(registerCallbackIfNoDataAvailable: false, out ClientRemotingDataPriority priority)) != null)
                {
                    peer.ProcessReceivedData(data, priority);
                }
            }

            internal void ProcessIncomingData(byte[] data, ClientRemotingDataPriority priority)
            {
                ProcessReceivedData(data, priority);
            }
        }

        private sealed class TestCommandTransportManager : BaseClientCommandTransportManager
        {
            internal TestCommandTransportManager(ClientCommandTransportCreationContext context)
                : base(context)
            {
            }

            public override void CreateAsync()
            {
            }

            protected internal override void ConnectAsync()
            {
            }

            internal Action<ReadOnlyMemory<byte>, ClientRemotingDataPriority> DataToSendAvailableCallback { get; set; }

            protected override void OnDataToSendAvailable(
                ReadOnlyMemory<byte> data,
                ClientRemotingDataPriority priority)
            {
                DataToSendAvailableCallback?.Invoke(data, priority);
            }

            internal string GetCommandText()
            {
                return CommandText;
            }

            internal byte[] ReadInitialData(bool registerCallbackIfNoDataAvailable)
            {
                return ReadInitialCommandData(registerCallbackIfNoDataAvailable);
            }

            internal void QueueAdditionalInitialData(RemoteDataObject<PSObject> data)
            {
                Fragmentor.Fragment<PSObject>(data, serializedPipeline);
            }
        }
    }
}
