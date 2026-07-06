// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System.Collections.Generic;
using System.Management.Automation.Internal;
using System.Management.Automation.Runspaces;
using System.Management.Automation.Runspaces.Internal;

namespace System.Management.Automation.Remoting.Client
{
    /// <summary>
    /// Priority of remoting data made available to a custom client transport.
    /// </summary>
    public enum ClientRemotingDataPriority
    {
        /// <summary>
        /// Default remoting data stream.
        /// </summary>
        Default = 0,

        /// <summary>
        /// Prompt response remoting data stream.
        /// </summary>
        PromptResponse = 1,
    }

    /// <summary>
    /// Context used to create a client remoting session transport.
    /// </summary>
    public sealed class ClientRemotingTransportCreationContext
    {
        /// <summary>
        /// Initializes a new instance of the <see cref="ClientRemotingTransportCreationContext"/> class.
        /// </summary>
        public ClientRemotingTransportCreationContext(
            Guid runspacePoolInstanceId,
            string sessionName,
            RunspaceConnectionInfo connectionInfo,
            PSRemotingCryptoHelper cryptoHelper)
        {
            ArgumentNullException.ThrowIfNull(connectionInfo);
            ArgumentNullException.ThrowIfNull(cryptoHelper);

            RunspacePoolInstanceId = runspacePoolInstanceId;
            SessionName = sessionName;
            ConnectionInfo = connectionInfo;
            CryptoHelper = cryptoHelper;
        }

        /// <summary>
        /// Gets the runspace pool instance identifier.
        /// </summary>
        public Guid RunspacePoolInstanceId { get; }

        /// <summary>
        /// Gets the session name.
        /// </summary>
        public string SessionName { get; }

        /// <summary>
        /// Gets the connection information.
        /// </summary>
        public RunspaceConnectionInfo ConnectionInfo { get; }

        /// <summary>
        /// Gets the remoting crypto helper.
        /// </summary>
        public PSRemotingCryptoHelper CryptoHelper { get; }
    }

    /// <summary>
    /// Context used to create a client remoting command transport.
    /// </summary>
    public sealed class ClientCommandTransportCreationContext
    {
        internal ClientCommandTransportCreationContext(
            RunspaceConnectionInfo connectionInfo,
            ClientRemotePowerShell remotePowerShell,
            bool noInput,
            BaseClientSessionTransportManager sessionTransportManager,
            PSRemotingCryptoHelper cryptoHelper)
        {
            ArgumentNullException.ThrowIfNull(connectionInfo);
            ArgumentNullException.ThrowIfNull(remotePowerShell);
            ArgumentNullException.ThrowIfNull(sessionTransportManager);
            ArgumentNullException.ThrowIfNull(cryptoHelper);

            ConnectionInfo = connectionInfo;
            RemotePowerShell = remotePowerShell;
            NoInput = noInput;
            SessionTransportManager = sessionTransportManager;
            CryptoHelper = cryptoHelper;
            RunspacePoolInstanceId = sessionTransportManager.RunspacePoolInstanceId;
            PowerShellInstanceId = remotePowerShell.InstanceId;
            CommandText = remotePowerShell.PowerShell.Commands.Commands.GetCommandStringForHistory();
        }

        /// <summary>
        /// Gets the runspace pool instance identifier.
        /// </summary>
        public Guid RunspacePoolInstanceId { get; }

        /// <summary>
        /// Gets the PowerShell instance identifier.
        /// </summary>
        public Guid PowerShellInstanceId { get; }

        /// <summary>
        /// Gets the connection information.
        /// </summary>
        public RunspaceConnectionInfo ConnectionInfo { get; }

        /// <summary>
        /// Gets the command text used by the transport protocol for audit and authorization.
        /// </summary>
        public string CommandText { get; }

        /// <summary>
        /// Gets a value indicating whether the command has no input.
        /// </summary>
        public bool NoInput { get; }

        /// <summary>
        /// Gets the session transport manager that owns the command transport.
        /// </summary>
        public BaseClientSessionTransportManager SessionTransportManager { get; }

        /// <summary>
        /// Gets the remoting crypto helper.
        /// </summary>
        public PSRemotingCryptoHelper CryptoHelper { get; }

        internal ClientRemotePowerShell RemotePowerShell { get; }
    }

    /// <summary>
    /// Creates custom client remoting session transports for connection information instances.
    /// </summary>
    public interface IClientRemotingTransportProvider
    {
        /// <summary>
        /// Determines whether this provider can create a transport for <paramref name="connectionInfo"/>.
        /// </summary>
        bool CanCreateTransport(RunspaceConnectionInfo connectionInfo);

        /// <summary>
        /// Creates a client remoting session transport.
        /// </summary>
        BaseClientSessionTransportManager CreateSessionTransport(
            ClientRemotingTransportCreationContext context);
    }

    /// <summary>
    /// Options used when registering a client remoting transport provider.
    /// </summary>
    public sealed class ClientRemotingTransportProviderOptions
    {
        /// <summary>
        /// Gets or sets a value indicating whether this provider can replace built-in transport handling.
        /// </summary>
        public bool ReplaceBuiltInTransports { get; set; }

        /// <summary>
        /// Gets or sets the provider priority. Higher priority providers are tried first.
        /// </summary>
        public int Priority { get; set; }
    }

    /// <summary>
    /// Process-scoped registry for client remoting transport providers.
    /// </summary>
    public static class ClientRemotingTransportProviderRegistry
    {
        private static readonly object s_syncObject = new object();
        private static readonly List<Registration> s_registrations = new List<Registration>();
        private static long s_nextRegistrationOrder;

        /// <summary>
        /// Registers a client remoting transport provider.
        /// </summary>
        public static IDisposable Register(
            IClientRemotingTransportProvider provider,
            ClientRemotingTransportProviderOptions options = null)
        {
            ArgumentNullException.ThrowIfNull(provider);

            options ??= new ClientRemotingTransportProviderOptions();

            lock (s_syncObject)
            {
                Registration registration = new Registration(
                    provider,
                    options.ReplaceBuiltInTransports,
                    options.Priority,
                    s_nextRegistrationOrder++);

                s_registrations.Add(registration);
                SortRegistrations();
                return registration;
            }
        }

        internal static bool CanCreateRunspacePoolTransport(RunspaceConnectionInfo connectionInfo)
        {
            ArgumentNullException.ThrowIfNull(connectionInfo);

            return IsBuiltInRunspacePoolConnectionInfo(connectionInfo)
                || connectionInfo.CanCreateClientRemotingTransport
                || TryGetProvider(connectionInfo, out _);
        }

        internal static bool WillUseRegisteredProvider(RunspaceConnectionInfo connectionInfo)
        {
            ArgumentNullException.ThrowIfNull(connectionInfo);

            return TryGetProvider(connectionInfo, out _);
        }

        internal static BaseClientSessionTransportManager CreateSessionTransport(
            ClientRemotingTransportCreationContext context)
        {
            ArgumentNullException.ThrowIfNull(context);

            if (TryGetProvider(context.ConnectionInfo, out IClientRemotingTransportProvider provider))
            {
                BaseClientSessionTransportManager transport = provider.CreateSessionTransport(context);
                return transport ?? throw PSTraceSource.NewInvalidOperationException(
                    RemotingErrorIdStrings.GeneralError,
                    0,
                    nameof(IClientRemotingTransportProvider.CreateSessionTransport));
            }

            BaseClientSessionTransportManager customTransport = context.ConnectionInfo.CreateClientSessionTransportManager(context);
            return customTransport ?? throw PSTraceSource.NewInvalidOperationException(
                RemotingErrorIdStrings.GeneralError,
                0,
                nameof(RunspaceConnectionInfo.CreateClientSessionTransportManager));
        }

        private static bool TryGetProvider(
            RunspaceConnectionInfo connectionInfo,
            out IClientRemotingTransportProvider provider)
        {
            Registration[] registrations;
            lock (s_syncObject)
            {
                registrations = s_registrations.ToArray();
            }

            bool isBuiltIn = IsBuiltInConnectionInfo(connectionInfo);
            foreach (Registration registration in registrations)
            {
                if (isBuiltIn && !registration.ReplaceBuiltInTransports)
                {
                    continue;
                }

                if (registration.Provider.CanCreateTransport(connectionInfo))
                {
                    provider = registration.Provider;
                    return true;
                }
            }

            provider = null;
            return false;
        }

        private static bool IsBuiltInConnectionInfo(RunspaceConnectionInfo connectionInfo)
        {
            return connectionInfo is WSManConnectionInfo
                || connectionInfo is NewProcessConnectionInfo
                || connectionInfo is NamedPipeConnectionInfo
                || connectionInfo is SSHConnectionInfo
                || connectionInfo is VMConnectionInfo
                || connectionInfo is ContainerConnectionInfo;
        }

        private static bool IsBuiltInRunspacePoolConnectionInfo(RunspaceConnectionInfo connectionInfo)
        {
            return connectionInfo is WSManConnectionInfo
                || connectionInfo is NewProcessConnectionInfo
                || connectionInfo is NamedPipeConnectionInfo
                || connectionInfo is VMConnectionInfo
                || connectionInfo is ContainerConnectionInfo;
        }

        private static void SortRegistrations()
        {
            s_registrations.Sort(static (left, right) =>
            {
                int priorityComparison = right.Priority.CompareTo(left.Priority);
                return priorityComparison != 0
                    ? priorityComparison
                    : left.RegistrationOrder.CompareTo(right.RegistrationOrder);
            });
        }

        private sealed class Registration : IDisposable
        {
            internal Registration(
                IClientRemotingTransportProvider provider,
                bool replaceBuiltInTransports,
                int priority,
                long registrationOrder)
            {
                Provider = provider;
                ReplaceBuiltInTransports = replaceBuiltInTransports;
                Priority = priority;
                RegistrationOrder = registrationOrder;
            }

            internal IClientRemotingTransportProvider Provider { get; }

            internal bool ReplaceBuiltInTransports { get; }

            internal int Priority { get; }

            internal long RegistrationOrder { get; }

            public void Dispose()
            {
                lock (s_syncObject)
                {
                    s_registrations.Remove(this);
                }
            }
        }
    }
}
