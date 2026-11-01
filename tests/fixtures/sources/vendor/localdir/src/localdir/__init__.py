"""A local directory requirement."""

__version__ = "0.3.0"


def main():
    from importlib.metadata import version

    import attrs
    import idna
    import six

    print(
        f"attrs={attrs.__version__} six={six.__version__} idna={idna.__version__} "
        f"iniconfig={version('iniconfig')} localdir={__version__}"
    )
