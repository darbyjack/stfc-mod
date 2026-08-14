-- Narrow CI experiment for XMake 3.1.0's protobuf.cpp rule.
-- Generation behavior stays the same; only generated C++ compilation is
-- wrapped with sccache so the experiment does not affect ordinary C++/Swift.

local rule_name = "stfc.protobuf.cpp.sccache"

local function _proto_paths(target, sourcefile_proto)
    local fileconfig = target:fileconfig(sourcefile_proto)
    if fileconfig and fileconfig.proto_grpc_cpp_plugin then
        raise("%s does not support proto_grpc_cpp_plugin", rule_name)
    end

    local prefixdir = fileconfig and fileconfig.proto_rootdir
    local autogendir = fileconfig and fileconfig.proto_autogendir
    local rootdir = autogendir or path.join(target:autogendir(), "rules", "protobuf")
    local filename = path.basename(sourcefile_proto) .. ".pb.cc"
    local sourcefile_cx = target:autogenfile(sourcefile_proto, {
        rootdir = rootdir,
        filename = filename
    })
    local sourcefile_dir = prefixdir and path.join(rootdir, prefixdir) or path.directory(sourcefile_cx)
    return sourcefile_cx, sourcefile_dir, prefixdir, fileconfig
end

local function _target_envs(target)
    return os.joinenvs(target:pkgenvs(), os.getenvs())
end

local function _get_protoc(target)
    local program = target:data("stfc.protobuf.protoc")
    if not program then
        local tool = find_tool("protoc", {envs = _target_envs(target)})
        program = assert(tool and tool.program, "protoc not found!")
        target:data_set("stfc.protobuf.protoc", program)
    end
    return program
end

local function _get_sccache(target, envs)
    local program = target:data("stfc.protobuf.sccache")
    if not program then
        local tool = find_tool("sccache", {norun = true, envs = envs})
        program = assert(tool and tool.program,
            "STFC_PROTOBUF_SCCACHE=1 but sccache was not found on PATH")
        target:data_set("stfc.protobuf.sccache", program)
    end
    return program
end

rule(rule_name)
    add_deps("c++")
    set_extensions(".proto")

    after_load(function(target)
        local sourcebatch = target:sourcebatches()[rule_name]
        for _, sourcefile_proto in ipairs(sourcebatch and sourcebatch.sourcefiles or {}) do
            local sourcefile_cx, sourcefile_dir, _, fileconfig = _proto_paths(target, sourcefile_proto)
            target:add("includedirs", sourcefile_dir, {
                public = fileconfig and fileconfig.proto_public or nil
            })
            table.insert(target:objectfiles(), target:objectfile(sourcefile_cx))
        end
    end)

    on_preparecmd_file(function(target, batchcmds, sourcefile_proto, opt)
        import("lib.detect.find_tool")

        local sourcefile_cx, sourcefile_dir, prefixdir, fileconfig = _proto_paths(target, sourcefile_proto)
        local protoc_args = {
            sourcefile_proto,
            "-I" .. (prefixdir or path.directory(sourcefile_proto)),
            "--cpp_out=" .. sourcefile_dir
        }
        if fileconfig and fileconfig.proto_flags then
            table.join2(protoc_args, fileconfig.proto_flags)
        end

        batchcmds:mkdir(sourcefile_dir)
        batchcmds:show_progress(opt.progress,
            "${color.build.object}compiling.proto.c++ %s", sourcefile_proto)
        batchcmds:vrunv(_get_protoc(target), protoc_args, {envs = _target_envs(target)})

        -- Preserve XMake 3.1.0's protobuf generation dependency behavior.
        batchcmds:add_depfiles(sourcefile_proto)
        batchcmds:set_depcache(target:dependfile(sourcefile_cx))
        batchcmds:set_depmtime(os.mtime(sourcefile_cx))
    end)

    on_buildcmd_file(function(target, batchcmds, sourcefile_proto, opt)
        import("core.tool.compiler")
        import("lib.detect.find_tool")

        local sourcefile_cx, sourcefile_dir = _proto_paths(target, sourcefile_proto)
        local objectfile = target:objectfile(sourcefile_cx)
        local compiler_inst = assert(compiler.load("cxx", {target = target}))

        -- rawargs is important on Windows: sccache, not cl.exe, is the immediate
        -- child process and must receive the logical compiler arguments once.
        local compiler_program, compiler_argv = compiler_inst:compargv(
            sourcefile_cx,
            path(objectfile),
            {
                target = target,
                configs = {includedirs = sourcefile_dir},
                rawargs = true
            })

        local envs = os.joinenvs(compiler_inst:runenvs(), os.getenvs())
        local sccache_args = {compiler_program}
        table.join2(sccache_args, compiler_argv)

        batchcmds:mkdir(path.directory(objectfile))
        batchcmds:show_progress(opt.progress,
            "${color.build.object}sccache compiling.proto.$(mode) %s", sourcefile_cx)
        batchcmds:vrunv(_get_sccache(target, envs), sccache_args, {envs = envs})

        -- Preserve the built-in rule's incremental metadata. Cross-run reuse is
        -- owned by sccache, whose key is based on compiler + args + preprocessed
        -- input, rather than these mtimes.
        batchcmds:add_depfiles(sourcefile_proto)
        batchcmds:set_depcache(target:dependfile(objectfile))
        batchcmds:set_depmtime(os.mtime(objectfile))
    end)
