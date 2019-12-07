--========================================================================================================================
-- Copyright (c) 2017 by Bitvis AS.  All rights reserved.
-- You should have received a copy of the license file containing the MIT License (see LICENSE.TXT), if not,
-- contact Bitvis AS <support@bitvis.no>.
--
-- UVVM AND ANY PART THEREOF ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
-- WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS
-- OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
-- OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH UVVM OR THE USE OR OTHER DEALINGS IN UVVM.
--========================================================================================================================

------------------------------------------------------------------------------------------
-- Description   : See library quick reference (under 'doc') and README-file(s)
--
-- NOTE: In addition to being a VVC for the SBI, this module is also used as a template
--       and a well commented example of the VVC structure and functionality
------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library uvvm_util;
context uvvm_util.uvvm_util_context;

library uvvm_vvc_framework;
use uvvm_vvc_framework.ti_vvc_framework_support_pkg.all;

library bitvis_vip_scoreboard;
use bitvis_vip_scoreboard.generic_sb_support_pkg.all;

use work.sbi_bfm_pkg.all;
use work.vvc_methods_pkg.all;
use work.vvc_cmd_pkg.all;
use work.td_target_support_pkg.all;
use work.td_vvc_entity_support_pkg.all;
use work.td_cmd_queue_pkg.all;
use work.td_result_queue_pkg.all;
use work.transaction_pkg.all;

--=================================================================================================
entity sbi_vvc is
  generic (
    GC_ADDR_WIDTH                            : integer range 1 to C_VVC_CMD_ADDR_MAX_LENGTH := 8;  -- SBI address bus
    GC_DATA_WIDTH                            : integer range 1 to C_VVC_CMD_DATA_MAX_LENGTH := 32;  -- SBI data bus
    GC_INSTANCE_IDX                          : natural                                      := 1;  -- Instance index for this SBI_VVCT instance
    GC_SBI_CONFIG                            : t_sbi_bfm_config                             := C_SBI_BFM_CONFIG_DEFAULT;  -- Behavior specification for BFM
    GC_CMD_QUEUE_COUNT_MAX                   : natural                                      := 1000;
    GC_CMD_QUEUE_COUNT_THRESHOLD             : natural                                      := 950;
    GC_CMD_QUEUE_COUNT_THRESHOLD_SEVERITY    : t_alert_level                                := warning;
    GC_RESULT_QUEUE_COUNT_MAX                : natural                                      := 1000;
    GC_RESULT_QUEUE_COUNT_THRESHOLD          : natural                                      := 950;
    GC_RESULT_QUEUE_COUNT_THRESHOLD_SEVERITY : t_alert_level                                := warning
    );
  port (
    clk               : in    std_logic;
    sbi_vvc_master_if : inout t_sbi_if(addr(GC_ADDR_WIDTH-1 downto 0),
                                       wdata(GC_DATA_WIDTH-1 downto 0),
                                       rdata(GC_DATA_WIDTH-1 downto 0)) := init_sbi_if_signals(GC_ADDR_WIDTH, GC_DATA_WIDTH)
    );
begin
  -- Check the interface widths to assure that the interface was correctly set up
  assert (sbi_vvc_master_if.addr'length = GC_ADDR_WIDTH) report "sbi_vvc_master_if.addr'length =/ GC_ADDR_WIDTH" severity failure;
  assert (sbi_vvc_master_if.wdata'length = GC_DATA_WIDTH) report "sbi_vvc_master_if.wdata'length =/ GC_DATA_WIDTH" severity failure;
  assert (sbi_vvc_master_if.rdata'length = GC_DATA_WIDTH) report "sbi_vvc_master_if.rdata'length =/ GC_DATA_WIDTH" severity failure;

end entity sbi_vvc;

--=================================================================================================
--=================================================================================================

architecture behave of sbi_vvc is

  constant C_SCOPE      : string       := C_VVC_NAME & "," & to_string(GC_INSTANCE_IDX);
  constant C_VVC_LABELS : t_vvc_labels := assign_vvc_labels(C_SCOPE, C_VVC_NAME, GC_INSTANCE_IDX, NA);

  signal executor_is_busy      : boolean := false;
  signal queue_is_increasing   : boolean := false;
  signal last_cmd_idx_executed : natural := 0;
  signal terminate_current_cmd : t_flag_record;

  -- Instantiation of the element dedicated Queue
  shared variable command_queue : work.td_cmd_queue_pkg.t_generic_queue;
  shared variable result_queue  : work.td_result_queue_pkg.t_generic_queue;

  alias vvc_config       : t_vvc_config is shared_sbi_vvc_config(GC_INSTANCE_IDX);
  alias vvc_status       : t_vvc_status is shared_sbi_vvc_status(GC_INSTANCE_IDX);
  alias transaction_info : t_transaction_info is shared_sbi_transaction_info(GC_INSTANCE_IDX);
  -- DTT
  alias dtt_transaction_info    : t_transaction_group is global_sbi_vvc_transaction(GC_INSTANCE_IDX);
  -- Activity Watchdog
  signal vvc_idx_for_activity_watchdog : integer;

begin


--===============================================================================================
-- Constructor
-- - Set up the defaults and show constructor if enabled
--===============================================================================================
  vvc_constructor(C_SCOPE, GC_INSTANCE_IDX, vvc_config, command_queue, result_queue, GC_SBI_CONFIG,
                  GC_CMD_QUEUE_COUNT_MAX, GC_CMD_QUEUE_COUNT_THRESHOLD, GC_CMD_QUEUE_COUNT_THRESHOLD_SEVERITY,
                  GC_RESULT_QUEUE_COUNT_MAX, GC_RESULT_QUEUE_COUNT_THRESHOLD, GC_RESULT_QUEUE_COUNT_THRESHOLD_SEVERITY);
--===============================================================================================


--===============================================================================================
-- Command interpreter
-- - Interpret, decode and acknowledge commands from the central sequencer
--===============================================================================================
  cmd_interpreter : process
     variable v_cmd_has_been_acked : boolean; -- Indicates if acknowledge_cmd() has been called for the current shared_vvc_cmd
     variable v_local_vvc_cmd      : t_vvc_cmd_record := C_VVC_CMD_DEFAULT;
     variable v_msg_id_panel       : t_msg_id_panel;
  begin

    -- 0. Initialize the process prior to first command
    initialize_interpreter(terminate_current_cmd, global_awaiting_completion);

    -- initialise shared_vvc_last_received_cmd_idx for channel and instance
    shared_vvc_last_received_cmd_idx(NA, GC_INSTANCE_IDX) := 0;

    -- Register VVC in activity watchdog register
    vvc_idx_for_activity_watchdog <= shared_activity_watchdog.priv_register_vvc(name      => "SBI",
                                                                                instance  => GC_INSTANCE_IDX);
    -- Set initial value of v_msg_id_panel to msg_id_panel in config
    v_msg_id_panel := vvc_config.msg_id_panel;

    -- Then for every single command from the sequencer
    loop  -- basically as long as new commands are received

      -- 1. wait until command targeted at this VVC. Must match VVC name, instance and channel (if applicable)
      --    releases global semaphore
      -------------------------------------------------------------------------
      await_cmd_from_sequencer(C_VVC_LABELS, vvc_config, THIS_VVCT, VVC_BROADCAST, global_vvc_busy, global_vvc_ack, v_local_vvc_cmd, v_msg_id_panel);
      v_cmd_has_been_acked := false; -- Clear flag
      -- update shared_vvc_last_received_cmd_idx with received command index
      shared_vvc_last_received_cmd_idx(NA, GC_INSTANCE_IDX) := v_local_vvc_cmd.cmd_idx;
      -- update v_msg_id_panel
      v_msg_id_panel := get_msg_id_panel(v_local_vvc_cmd, vvc_config);

      -- 2a. Put command on the queue if intended for the executor
      -------------------------------------------------------------------------
      if v_local_vvc_cmd.command_type = QUEUED then
        put_command_on_queue(v_local_vvc_cmd, command_queue, vvc_status, queue_is_increasing);


        -- 2b. Otherwise command is intended for immediate response
        -------------------------------------------------------------------------
      elsif v_local_vvc_cmd.command_type = IMMEDIATE then
        case v_local_vvc_cmd.operation is

          when AWAIT_COMPLETION =>
            interpreter_await_completion(v_local_vvc_cmd, command_queue, vvc_config, executor_is_busy, C_VVC_LABELS, last_cmd_idx_executed);

          when AWAIT_ANY_COMPLETION =>
            if not v_local_vvc_cmd.gen_boolean then
              -- Called with lastness = NOT_LAST: Acknowledge immediately to let the sequencer continue
              acknowledge_cmd(global_vvc_ack,v_local_vvc_cmd.cmd_idx);
              v_cmd_has_been_acked := true;
            end if;
            interpreter_await_any_completion(v_local_vvc_cmd, command_queue, vvc_config, executor_is_busy, C_VVC_LABELS, last_cmd_idx_executed, global_awaiting_completion);

          when DISABLE_LOG_MSG =>
            disable_log_msg(v_local_vvc_cmd.msg_id, vvc_config.msg_id_panel, to_string(v_local_vvc_cmd.msg) & format_command_idx(v_local_vvc_cmd), C_SCOPE, v_local_vvc_cmd.quietness);

          when ENABLE_LOG_MSG =>
            enable_log_msg(v_local_vvc_cmd.msg_id, vvc_config.msg_id_panel, to_string(v_local_vvc_cmd.msg) & format_command_idx(v_local_vvc_cmd), C_SCOPE, v_local_vvc_cmd.quietness);

          when FLUSH_COMMAND_QUEUE =>
            interpreter_flush_command_queue(v_local_vvc_cmd, command_queue, vvc_config, vvc_status, C_VVC_LABELS);

          when TERMINATE_CURRENT_COMMAND =>
            interpreter_terminate_current_command(v_local_vvc_cmd, vvc_config, C_VVC_LABELS, terminate_current_cmd);

          when FETCH_RESULT =>
            interpreter_fetch_result(result_queue, v_local_vvc_cmd, vvc_config, C_VVC_LABELS, last_cmd_idx_executed, shared_vvc_response);

          when others =>
            tb_error("Unsupported command received for IMMEDIATE execution: '" & to_string(v_local_vvc_cmd.operation) & "'", C_SCOPE);

        end case;

      else
        tb_error("command_type is not IMMEDIATE or QUEUED", C_SCOPE);
      end if;

      -- 3. Acknowledge command after runing or queuing the command
      -------------------------------------------------------------------------
      if not v_cmd_has_been_acked then
        acknowledge_cmd(global_vvc_ack,v_local_vvc_cmd.cmd_idx);
      end if;

    end loop;
  end process;
--===============================================================================================



--===============================================================================================
-- Command executor
-- - Fetch and execute the commands
--===============================================================================================
  cmd_executor : process
    variable v_cmd                                   : t_vvc_cmd_record;
    variable v_read_data                             : t_vvc_result;  -- See vvc_cmd_pkg
    variable v_timestamp_start_of_current_bfm_access : time     := 0 ns;
    variable v_timestamp_start_of_last_bfm_access    : time     := 0 ns;
    variable v_timestamp_end_of_last_bfm_access      : time     := 0 ns;
    variable v_command_is_bfm_access                 : boolean  := false;
    variable v_prev_command_was_bfm_access           : boolean  := false;
    variable v_normalised_addr                       : unsigned(GC_ADDR_WIDTH-1 downto 0)         := (others => '0');
    variable v_normalised_data                       : std_logic_vector(GC_DATA_WIDTH-1 downto 0) := (others => '0');
    variable v_msg_id_panel                          : t_msg_id_panel;

  begin

    -- 0. Initialize the process prior to first command
    -------------------------------------------------------------------------
    initialize_executor(terminate_current_cmd);
    -- Set initial value of v_msg_id_panel to msg_id_panel in config
    v_msg_id_panel := vvc_config.msg_id_panel;


    -- Setup SBI scoreboard
    shared_sbi_sb.set_scope("SBI_VVC");
    shared_sbi_sb.enable(GC_INSTANCE_IDX, "SB SBI Enabled");
    shared_sbi_sb.config(GC_INSTANCE_IDX, C_SB_CONFIG_DEFAULT);
    shared_sbi_sb.enable_log_msg(ID_DATA);

    loop

      -- Notify activity watchdog
      activity_watchdog_register_vvc_state(global_trigger_activity_watchdog, false, vvc_idx_for_activity_watchdog, last_cmd_idx_executed, C_SCOPE);

      -- 1. Set defaults, fetch command and log
      -------------------------------------------------------------------------
      fetch_command_and_prepare_executor(v_cmd, command_queue, vvc_config, vvc_status, queue_is_increasing, executor_is_busy, C_VVC_LABELS, v_msg_id_panel);

      -- Notify activity watchdog
      activity_watchdog_register_vvc_state(global_trigger_activity_watchdog, true, vvc_idx_for_activity_watchdog, last_cmd_idx_executed, C_SCOPE);


      -- Set the transaction info for waveview
      transaction_info           := C_TRANSACTION_INFO_DEFAULT;
      transaction_info.operation := v_cmd.operation;
      transaction_info.msg       := pad_string(to_string(v_cmd.msg), ' ', transaction_info.msg'length);

      -- update v_msg_id_panel
      v_msg_id_panel := get_msg_id_panel(v_cmd, vvc_config);

      -- Check if command is a BFM access
      v_prev_command_was_bfm_access := v_command_is_bfm_access; -- save for inter_bfm_delay
      if v_cmd.operation = WRITE or v_cmd.operation = READ or v_cmd.operation = CHECK or v_cmd.operation = POLL_UNTIL then
        v_command_is_bfm_access := true;
      else
        v_command_is_bfm_access := false;
      end if;

      -- Insert delay if needed
      insert_inter_bfm_delay_if_requested(vvc_config                         => vvc_config,
                                          command_is_bfm_access              => v_prev_command_was_bfm_access,
                                          timestamp_start_of_last_bfm_access => v_timestamp_start_of_last_bfm_access,
                                          timestamp_end_of_last_bfm_access   => v_timestamp_end_of_last_bfm_access,
                                          scope                              => C_SCOPE,
                                          msg_id_panel                       => v_msg_id_panel);

      if v_command_is_bfm_access then
        v_timestamp_start_of_current_bfm_access := now;
      end if;

      -- 2. Execute the fetched command
      -------------------------------------------------------------------------
      case v_cmd.operation is  -- Only operations in the dedicated record are relevant

        -- VVC dedicated operations
        --===================================
        when WRITE =>
          -- Loop the number of words to transmit
          for idx in 1 to v_cmd.num_words loop

            -- Randomise data if applicable
            case v_cmd.randomisation is
              when RANDOM =>
                v_cmd.data := std_logic_vector(to_unsigned(random(0, 16), v_cmd.data'length)); -- Hard coded for TB example
              when RANDOM_FAVOUR_EDGES =>
                null; -- Not implemented yet
              when others => -- NA
                null;
            end case;

            -- Set DTT
            set_global_dtt(dtt_transaction_info, v_cmd, vvc_config);

            -- Normalise address and data
            v_normalised_addr := normalize_and_check(v_cmd.addr, v_normalised_addr, ALLOW_WIDER_NARROWER, "addr", "shared_vvc_cmd.addr", "sbi_write() called with to wide addrress. " & v_cmd.msg);
            v_normalised_data := normalize_and_check(v_cmd.data, v_normalised_data, ALLOW_WIDER_NARROWER, "data", "shared_vvc_cmd.data", "sbi_write() called with to wide data. " & v_cmd.msg);

            transaction_info.data(GC_DATA_WIDTH - 1 downto 0) := v_normalised_data;
            transaction_info.addr(GC_ADDR_WIDTH - 1 downto 0) := v_normalised_addr;
            -- Call the corresponding procedure in the BFM package.
            sbi_write(addr_value   => v_normalised_addr,
                      data_value   => v_normalised_data,
                      msg          => format_msg(v_cmd),
                      clk          => clk,
                      sbi_if       => sbi_vvc_master_if,
                      scope        => C_SCOPE,
                      msg_id_panel => v_msg_id_panel,
                      config       => vvc_config.bfm_config);

            -- Set DTT back to default values
            restore_global_dtt(dtt_transaction_info, v_cmd);
          end loop;


        when READ =>
          -- Set DTT
          set_global_dtt(dtt_transaction_info, v_cmd, vvc_config);

          -- Normalise address and data
          v_normalised_addr := normalize_and_check(v_cmd.addr, v_normalised_addr, ALLOW_WIDER_NARROWER, "addr", "shared_vvc_cmd.addr", "sbi_read() called with to wide addrress. " & v_cmd.msg);

          v_read_data := (others => '-');
          transaction_info.addr(GC_ADDR_WIDTH - 1 downto 0) := v_normalised_addr;
          -- Call the corresponding procedure in the BFM package.
          sbi_read(addr_value   => v_normalised_addr,
                   data_value   => v_read_data(GC_DATA_WIDTH - 1 downto 0),
                   msg          => format_msg(v_cmd),
                   clk          => clk,
                   sbi_if       => sbi_vvc_master_if,
                   scope        => C_SCOPE,
                   msg_id_panel => v_msg_id_panel,
                   config       => vvc_config.bfm_config);

          -- Request SB check result
          if v_cmd.data_routing = TO_SB then
            -- call SB check_recevide
            shared_sbi_sb.check_received(GC_INSTANCE_IDX, v_read_data(GC_DATA_WIDTH-1 downto 0));
          else
            work.td_vvc_entity_support_pkg.store_result(result_queue => result_queue,
                                                         cmd_idx     => v_cmd.cmd_idx,
                                                         result      => v_read_data);
          end if;


        when CHECK =>
          -- Set DTT
          set_global_dtt(dtt_transaction_info, v_cmd, vvc_config);

          -- Normalise address and data
          v_normalised_addr := normalize_and_check(v_cmd.addr, v_normalised_addr, ALLOW_WIDER_NARROWER, "addr", "shared_vvc_cmd.addr", "sbi_check() called with to wide addrress. " & v_cmd.msg);
          v_normalised_data := normalize_and_check(v_cmd.data, v_normalised_data, ALLOW_WIDER_NARROWER, "data", "shared_vvc_cmd.data", "sbi_check() called with to wide data. " & v_cmd.msg);

          transaction_info.data(GC_DATA_WIDTH - 1 downto 0) := v_normalised_data;
          transaction_info.addr(GC_ADDR_WIDTH - 1 downto 0) := v_normalised_addr;
          -- Call the corresponding procedure in the BFM package.
          sbi_check(addr_value   => v_normalised_addr,
                    data_exp     => v_normalised_data,
                    msg          => format_msg(v_cmd),
                    clk          => clk,
                    sbi_if       => sbi_vvc_master_if,
                    alert_level  => v_cmd.alert_level,
                    scope        => C_SCOPE,
                    msg_id_panel => v_msg_id_panel,
                    config       => vvc_config.bfm_config);


        when POLL_UNTIL =>
          -- Set DTT
          set_global_dtt(dtt_transaction_info, v_cmd, vvc_config);

          -- Normalise address and data
          v_normalised_addr := normalize_and_check(v_cmd.addr, v_normalised_addr, ALLOW_WIDER_NARROWER, "addr", "shared_vvc_cmd.addr", "sbi_poll_until() called with to wide addrress. " & v_cmd.msg);
          v_normalised_data := normalize_and_check(v_cmd.data, v_normalised_data, ALLOW_WIDER_NARROWER, "data", "shared_vvc_cmd.data", "sbi_poll_until() called with to wide data. " & v_cmd.msg);

          transaction_info.data(GC_DATA_WIDTH - 1 downto 0) := v_normalised_data;
          transaction_info.addr(GC_ADDR_WIDTH - 1 downto 0) := v_normalised_addr;
          -- Call the corresponding procedure in the BFM package.
          sbi_poll_until(addr_value     => v_normalised_addr,
                         data_exp       => v_normalised_data,
                         max_polls      => v_cmd.max_polls,
                         timeout        => v_cmd.timeout,
                         msg            => format_msg(v_cmd),
                         clk            => clk,
                         sbi_if         => sbi_vvc_master_if,
                         terminate_loop => terminate_current_cmd.is_active,
                         alert_level    => v_cmd.alert_level,
                         scope          => C_SCOPE,
                         msg_id_panel   => v_msg_id_panel,
                         config         => vvc_config.bfm_config);



          -- UVVM common operations
          --===================================
        when INSERT_DELAY =>
          log(ID_INSERTED_DELAY, "Running: " & to_string(v_cmd.proc_call) & " " & format_command_idx(v_cmd), C_SCOPE, v_msg_id_panel);
          if v_cmd.gen_integer_array(0) = -1 then
            -- Delay specified using time
            wait until terminate_current_cmd.is_active = '1' for v_cmd.delay;
          else
            -- Delay specified using integer
            wait until terminate_current_cmd.is_active = '1' for v_cmd.gen_integer_array(0) * vvc_config.bfm_config.clock_period;
          end if;

        when others =>
          tb_error("Unsupported local command received for execution: '" & to_string(v_cmd.operation) & "'", C_SCOPE);
      end case;

      if v_command_is_bfm_access then
        v_timestamp_end_of_last_bfm_access   := now;
        v_timestamp_start_of_last_bfm_access := v_timestamp_start_of_current_bfm_access;
        if ((vvc_config.inter_bfm_delay.delay_type = TIME_START2START) and
            ((now - v_timestamp_start_of_current_bfm_access) > vvc_config.inter_bfm_delay.delay_in_time)) then
          alert(vvc_config.inter_bfm_delay.inter_bfm_delay_violation_severity, "BFM access exceeded specified start-to-start inter-bfm delay, " &
                to_string(vvc_config.inter_bfm_delay.delay_in_time) & ".", C_SCOPE);
        end if;
      end if;

      -- Reset terminate flag if any occurred
      if (terminate_current_cmd.is_active = '1') then
        log(ID_CMD_EXECUTOR, "Termination request received", C_SCOPE, v_msg_id_panel);
        reset_flag(terminate_current_cmd);
      end if;

      last_cmd_idx_executed <= v_cmd.cmd_idx;
      -- Reset the transaction info for waveview
      transaction_info      := C_TRANSACTION_INFO_DEFAULT;

      -- Set DTT back to default values
      restore_global_dtt(dtt_transaction_info, v_cmd);
    end loop;
  end process;
  --===============================================================================================


--===============================================================================================
-- Command termination handler
-- - Handles the termination request record (sets and resets terminate flag on request)
--===============================================================================================
  cmd_terminator : uvvm_vvc_framework.ti_vvc_framework_support_pkg.flag_handler(terminate_current_cmd);  -- flag: is_active, set, reset
--===============================================================================================

end behave;


