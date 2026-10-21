
DefinitionBlock ("", "SSDT", 2, "DECK", "CUSTOM", 0x00000001)
{
    External (_SB_.PCI0, DeviceObj)
    External (_SB_.PCI0.GP17, DeviceObj)  
    External (_SB_.PCI0.GP17.SDEV, DeviceObj)

    Scope (\_SB.PCI0)
    {
        Method (_DSM, 4, NotSerialized)  
        {
            If (LEqual (Arg0, ToUUID ("c6c7a2b7-0e9a-4c8e-9f2b-0f8a5e3d4c2b")))  
            {
                Return (Package ()
                {
                    "kUSBSleepPowerSupply",     0x0A5A,      
                    "kUSBSleepPortCurrentLimit",0x0834,
                    "kUSBWakePowerSupply",      0x0A5A,
                    "kUSBWakePortCurrentLimit", 0x0834
                })
            }
            Return (Package() { })
        }
    }

    Scope (\_SB.PCI0.GP17.SDEV)
    {
        Name (_S0W, 0x03)     
        Method (_DSM, 4, NotSerialized)
        {
            If (LEqual (Arg0, ToUUID ("d4a50b75-65c7-46f7-9c7e-3f4b6f5e2a1b")))
            {
                Return (Package ()
                {
                    "NVMeLowestPowerState", One
                })
            }
            Return (Package() { })
        }
    }

    Scope (\_SB)
    {
        Device (PNLF)
        {
            Name (_HID, "APP0002")  
            Name (_CID, "backlight")
        }
    }

    Scope (\_GPE)
    {
        Method (_Lxx, 0, NotSerialized)  
        {

        }
    }
}
