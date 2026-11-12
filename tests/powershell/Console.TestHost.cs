using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;
using System.Threading;

public sealed class SeedTestHost : PSHost {
    readonly Guid id = Guid.NewGuid();
    public readonly SeedTestUI Terminal = new SeedTestUI();
    public override Guid InstanceId => id;
    public override string Name => "SeedTestHost";
    public override Version Version => new Version(1,0);
    public override PSHostUserInterface UI => Terminal;
    public override CultureInfo CurrentCulture => CultureInfo.InvariantCulture;
    public override CultureInfo CurrentUICulture => CultureInfo.InvariantCulture;
    public override void EnterNestedPrompt() { throw new NotSupportedException(); }
    public override void ExitNestedPrompt() { throw new NotSupportedException(); }
    public override void NotifyBeginApplication() {}
    public override void NotifyEndApplication() {}
    public override void SetShouldExit(int exitCode) {}
}
public sealed class SeedTestUI : PSHostUserInterface {
    public readonly BlockingCollection<string> Answers = new BlockingCollection<string>();
    public readonly ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
    public readonly ManualResetEventSlim Reading = new ManualResetEventSlim(false);
    public int Reads;
    public override PSHostRawUserInterface RawUI => null;
    public override string ReadLine() { Interlocked.Increment(ref Reads); Reading.Set(); return Answers.Take(); }
    public override SecureString ReadLineAsSecureString() { throw new NotSupportedException(); }
    public override void Write(string value) { Lines.Enqueue(value); }
    public override void Write(ConsoleColor fg, ConsoleColor bg, string value) { Write(value); }
    public override void WriteLine(string value) { Write(value); }
    public override void WriteErrorLine(string value) { Write(value); }
    public override void WriteDebugLine(string value) { Write(value); }
    public override void WriteProgress(long sourceId, ProgressRecord record) {}
    public override void WriteVerboseLine(string value) { Write(value); }
    public override void WriteWarningLine(string value) { Write(value); }
    public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions) { throw new NotSupportedException(); }
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) { throw new NotSupportedException(); }
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName, PSCredentialTypes types, PSCredentialUIOptions options) { throw new NotSupportedException(); }
    public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice) { throw new NotSupportedException(); }
}
