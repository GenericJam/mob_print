%% mob_print_nif — Erlang NIF module for the system PDF print plugin.
%%
%% Android: priv/native/jni/mob_print_nif.zig (Zig NIF bridging to the Kotlin
%% io.mob.print.MobPrintBridge object, which drives Android's PrintManager).
%% iOS: priv/native/ios/mob_print_nif.m (Objective-C NIF presenting
%% UIPrintInteractionController with the PDF file URL). Both register this
%% module via ERL_NIF_INIT and are statically linked into the host binary on
%% device. On a host dev build neither is linked, so on_load tolerates the
%% failure and print_pdf/2 answers {error, unsupported}.
-module(mob_print_nif).
-export([print_pdf/2]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_print_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

print_pdf(_Path, _Title) ->
    {error, unsupported}.
